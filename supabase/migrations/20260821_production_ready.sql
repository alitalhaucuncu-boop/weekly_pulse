-- 1. profiles Tablosu ve Yetki İzolasyonu
CREATE TABLE IF NOT EXISTS public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email text,
    birth_date text,
    is_premium boolean NOT NULL DEFAULT false,
    tier_name text NOT NULL DEFAULT 'Free',
    plan_id text NOT NULL DEFAULT 'free',
    subscription_start timestamptz,
    subscription_end timestamptz,
    auto_renew boolean NOT NULL DEFAULT false,
    voice_usage int NOT NULL DEFAULT 0,
    ai_usage int NOT NULL DEFAULT 0,
    last_usage_week text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS birth_date text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS last_usage_week text;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_select_policy ON public.profiles;
CREATE POLICY profiles_select_policy ON public.profiles
    FOR SELECT
    USING (auth.uid() = id);

-- İstemciden kritik kolonlara doğrudan yazma yetkilerini tamamen kaldır
REVOKE INSERT (is_premium, voice_usage, ai_usage, tier_name, plan_id, subscription_start, subscription_end) ON public.profiles FROM anon, authenticated;
REVOKE UPDATE (is_premium, voice_usage, ai_usage, tier_name, plan_id, subscription_start, subscription_end) ON public.profiles FROM anon, authenticated;

-- Otomatik Profil Trigger'ı
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, is_premium, tier_name, plan_id, voice_usage, ai_usage, last_usage_week)
    VALUES (new.id, new.email, false, 'Free', 'free', 0, 0, to_char(date_trunc('week', now()), 'IYYY-IW'))
    ON CONFLICT (id) DO NOTHING;
    RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Profil Tamamlama RPC (Doğum Tarihi)
CREATE OR REPLACE FUNCTION public.complete_user_profile(p_birth_date text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    UPDATE public.profiles
    SET birth_date = p_birth_date,
        updated_at = now()
    WHERE id = v_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.complete_user_profile(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_user_profile(text) TO authenticated;

-- Profil Durumu ve Sunucu Tarafı Kota Senkronizasyon RPC'si
CREATE OR REPLACE FUNCTION public.sync_my_profile_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_is_premium boolean;
    v_tier_name text;
    v_plan_id text;
    v_sub_end timestamptz;
    v_voice_usage int;
    v_ai_usage int;
    v_last_week text;
    v_current_week text := to_char(date_trunc('week', now()), 'IYYY-IW');
    v_changed boolean := false;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    SELECT is_premium, tier_name, plan_id, subscription_end, voice_usage, ai_usage, last_usage_week
    INTO v_is_premium, v_tier_name, v_plan_id, v_sub_end, v_voice_usage, v_ai_usage, v_last_week
    FROM public.profiles WHERE id = v_user_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Profil bulunamadı.');
    END IF;

    IF v_is_premium AND v_sub_end IS NOT NULL AND v_sub_end < now() THEN
        v_is_premium := false;
        v_tier_name := 'Free';
        v_plan_id := 'free';
        v_changed := true;
    END IF;

    IF v_last_week IS DISTINCT FROM v_current_week THEN
        v_voice_usage := 0;
        v_ai_usage := 0;
        v_last_week := v_current_week;
        v_changed := true;
    END IF;

    IF v_changed THEN
        UPDATE public.profiles SET
            is_premium = v_is_premium,
            tier_name = v_tier_name,
            plan_id = v_plan_id,
            auto_renew = CASE WHEN v_is_premium THEN auto_renew ELSE false END,
            voice_usage = v_voice_usage,
            ai_usage = v_ai_usage,
            last_usage_week = v_last_week,
            updated_at = now()
        WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'is_premium', v_is_premium,
        'tier_name', v_tier_name,
        'plan_id', v_plan_id,
        'voice_usage', v_voice_usage,
        'ai_usage', v_ai_usage
    );
END;
$$;

REVOKE ALL ON FUNCTION public.sync_my_profile_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_my_profile_status() TO authenticated;

-- Abonelik İptali RPC (Güvenli Downgrade)
CREATE OR REPLACE FUNCTION public.cancel_my_subscription()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    UPDATE public.profiles
    SET is_premium = false,
        tier_name = 'Free',
        plan_id = 'free',
        auto_renew = false,
        updated_at = now()
    WHERE id = v_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_my_subscription() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_my_subscription() TO authenticated;

-- mock_store_purchase fonksiyonunu düşür
DROP FUNCTION IF EXISTS public.mock_store_purchase(text, text, boolean);

-- 2. weekly_tasks Tablosu ve Monotonik Versiyon Kolonu
CREATE TABLE IF NOT EXISTS public.weekly_tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title text NOT NULL,
    category text NOT NULL,
    day_index int NOT NULL,
    scheduled_date text NOT NULL,
    week_start_date text NOT NULL,
    task_mode text NOT NULL DEFAULT 'student',
    task_time text NOT NULL,
    duration_minutes int NOT NULL DEFAULT 60,
    priority text NOT NULL DEFAULT 'Orta',
    deadline timestamptz,
    reminder_time text NOT NULL DEFAULT '1 Saat Önce',
    is_completed boolean NOT NULL DEFAULT false,
    calendar_id text,
    calendar_event_id text,
    notification_id int,
    sync_status text NOT NULL DEFAULT 'pending',
    sync_warning text,
    sync_error_code text,
    last_synced_at timestamptz DEFAULT now(),
    version int NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Idempotent Upgrade Migration Komutları
ALTER TABLE public.weekly_tasks ADD COLUMN IF NOT EXISTS version int NOT NULL DEFAULT 1;
ALTER TABLE public.weekly_tasks ADD COLUMN IF NOT EXISTS sync_status text NOT NULL DEFAULT 'pending';
ALTER TABLE public.weekly_tasks ADD COLUMN IF NOT EXISTS sync_warning text;
ALTER TABLE public.weekly_tasks ADD COLUMN IF NOT EXISTS sync_error_code text;
ALTER TABLE public.weekly_tasks ADD COLUMN IF NOT EXISTS last_synced_at timestamptz DEFAULT now();

ALTER TABLE public.weekly_tasks DROP CONSTRAINT IF EXISTS chk_duration;
ALTER TABLE public.weekly_tasks ADD CONSTRAINT chk_duration CHECK (duration_minutes BETWEEN 15 AND 480);

ALTER TABLE public.weekly_tasks DROP CONSTRAINT IF EXISTS chk_day_index;
ALTER TABLE public.weekly_tasks ADD CONSTRAINT chk_day_index CHECK (day_index BETWEEN 0 AND 6);

ALTER TABLE public.weekly_tasks DROP CONSTRAINT IF EXISTS chk_priority;
ALTER TABLE public.weekly_tasks ADD CONSTRAINT chk_priority CHECK (priority IN ('Düşük', 'Orta', 'Yüksek', 'Kritik'));

CREATE INDEX IF NOT EXISTS idx_weekly_tasks_user_week ON public.weekly_tasks(user_id, week_start_date);
CREATE INDEX IF NOT EXISTS idx_weekly_tasks_user_date ON public.weekly_tasks(user_id, scheduled_date);

ALTER TABLE public.weekly_tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS weekly_tasks_user_policy ON public.weekly_tasks;
CREATE POLICY weekly_tasks_user_policy ON public.weekly_tasks
    FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- 3. Atomic AI Quota Sistemi
CREATE TABLE IF NOT EXISTS public.ai_quota_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    request_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ai_quota_logs_user_req_unique UNIQUE (user_id, request_id)
);

ALTER TABLE public.ai_quota_logs ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.ai_quota_logs FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.consume_ai_quota(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_ai_usage int;
    v_is_premium boolean;
    v_last_week text;
    v_current_week text := to_char(date_trunc('week', now()), 'IYYY-IW');
    v_inserted_log_id uuid;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    IF p_request_id IS NULL OR length(p_request_id) < 8 OR length(p_request_id) > 128 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Geçersiz istek tanımlayıcısı.');
    END IF;

    SELECT ai_usage, is_premium, last_usage_week INTO v_ai_usage, v_is_premium, v_last_week
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Profil bulunamadı.');
    END IF;

    IF v_last_week IS DISTINCT FROM v_current_week THEN
        v_ai_usage := 0;
        UPDATE public.profiles
        SET ai_usage = 0,
            last_usage_week = v_current_week
        WHERE id = v_user_id;
    END IF;

    INSERT INTO public.ai_quota_logs (user_id, request_id)
    VALUES (v_user_id, p_request_id)
    ON CONFLICT (user_id, request_id) DO NOTHING
    RETURNING id INTO v_inserted_log_id;

    IF v_inserted_log_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'ai_usage', v_ai_usage,
            'is_premium', v_is_premium,
            'idempotent', true
        );
    END IF;

    IF NOT v_is_premium AND v_ai_usage >= 1 THEN
        DELETE FROM public.ai_quota_logs WHERE id = v_inserted_log_id;
        RETURN jsonb_build_object('success', false, 'message', 'Haftalık akıllı analiz kotanız doldu.');
    END IF;

    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET ai_usage = ai_usage + 1,
            last_usage_week = v_current_week
        WHERE id = v_user_id;
        v_ai_usage := v_ai_usage + 1;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'ai_usage', v_ai_usage,
        'is_premium', v_is_premium,
        'idempotent', false
    );
END;
$$;

REVOKE ALL ON FUNCTION public.consume_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_ai_quota(text) TO authenticated;