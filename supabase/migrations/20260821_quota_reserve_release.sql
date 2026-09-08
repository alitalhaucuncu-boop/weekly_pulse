-- Voice Quota Reservations Tablosu
CREATE TABLE IF NOT EXISTS public.voice_quota_reservations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    request_id text NOT NULL,
    task_id uuid REFERENCES public.weekly_tasks(id) ON DELETE SET NULL,
    status text NOT NULL DEFAULT 'committed',
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '2 minutes'),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT voice_quota_req_unique UNIQUE (user_id, request_id)
);

ALTER TABLE public.voice_quota_reservations ENABLE ROW LEVEL SECURITY;
REVOKE INSERT, UPDATE, DELETE ON public.voice_quota_reservations FROM anon, authenticated;

DROP POLICY IF EXISTS voice_quota_select_policy ON public.voice_quota_reservations;
CREATE POLICY voice_quota_select_policy ON public.voice_quota_reservations
    FOR SELECT USING (auth.uid() = user_id);

-- P0 Çözümü: Eski Stublar Fail-Closed (Sahte Başarı Asla Dönülmez, Bypass Engellenir)[cite: 5]
CREATE OR REPLACE FUNCTION public.reserve_voice_quota(p_request_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    RETURN jsonb_build_object('success', false, 'code', 'deprecated_api', 'message', 'create_voice_task_with_quota kullanınız.');
END; $$;

CREATE OR REPLACE FUNCTION public.commit_voice_quota(p_request_id text, p_task_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    RETURN jsonb_build_object('success', false, 'code', 'deprecated_api', 'message', 'create_voice_task_with_quota kullanınız.');
END; $$;

CREATE OR REPLACE FUNCTION public.release_voice_quota(p_request_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    RETURN jsonb_build_object('success', false, 'code', 'deprecated_api', 'message', 'create_voice_task_with_quota kullanınız.');
END; $$;

-- P0 Çözümü: Race-Safe FOR UPDATE Kilitli ve Tam Idempotent Voice RPC'si[cite: 5]
CREATE OR REPLACE FUNCTION public.create_voice_task_with_quota(
    p_request_id text,
    p_title text,
    p_category text,
    p_day_index int,
    p_scheduled_date text,
    p_week_start_date text,
    p_task_time text,
    p_duration_minutes int,
    p_priority text,
    p_deadline timestamptz,
    p_reminder_time text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_is_premium boolean;
    v_voice_usage int;
    v_last_week text;
    v_current_week text := to_char(date_trunc('week', now()), 'IYYY-IW');
    v_existing_task_id uuid;
    v_existing_task public.weekly_tasks%ROWTYPE;
    v_task_record public.weekly_tasks%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    IF p_request_id IS NULL OR length(p_request_id) < 8 OR length(p_request_id) > 128 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Geçersiz istek tanımlayıcısı.');
    END IF;

    -- 1. Kullanıcı Profili Satırını Kilitle (Eşzamanlı Yarışları Sıraya Koy)[cite: 5]
    SELECT is_premium, voice_usage, last_usage_week
    INTO v_is_premium, v_voice_usage, v_last_week
    FROM public.profiles
    WHERE id = v_user_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Profil bulunamadı.');
    END IF;

    -- 2. Kilit Altında Deterministik Idempotency Kontrolü
    SELECT task_id INTO v_existing_task_id 
    FROM public.voice_quota_reservations 
    WHERE user_id = v_user_id AND request_id = p_request_id;

    IF v_existing_task_id IS NOT NULL THEN
        SELECT * INTO v_existing_task FROM public.weekly_tasks WHERE id = v_existing_task_id;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'success', true,
                'task', to_jsonb(v_existing_task),
                'idempotent', true
            );
        END IF;
    END IF;

    -- 3. Haftalık Rollover
    IF v_last_week IS DISTINCT FROM v_current_week THEN
        v_voice_usage := 0;
        UPDATE public.profiles
        SET voice_usage = 0, last_usage_week = v_current_week
        WHERE id = v_user_id;
    END IF;

    -- 4. Kota Sınırı
    IF NOT v_is_premium AND v_voice_usage >= 3 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Haftalık sesli komut kotanız doldu.');
    END IF;

    -- 5. Görevi Atomik Oluştur
    INSERT INTO public.weekly_tasks (
        user_id, title, category, day_index, scheduled_date, week_start_date,
        task_mode, task_time, duration_minutes, priority, deadline, reminder_time,
        version, sync_status
    )
    VALUES (
        v_user_id, p_title, p_category, p_day_index, p_scheduled_date, p_week_start_date,
        'student', p_task_time, p_duration_minutes, p_priority, p_deadline, p_reminder_time,
        1, 'pending'
    )
    RETURNING * INTO v_task_record;

    -- 6. Kotayı Güncelle ve Rezervasyon Logunu Committed Olarak Mühürle
    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET voice_usage = voice_usage + 1, last_usage_week = v_current_week
        WHERE id = v_user_id;
    END IF;

    INSERT INTO public.voice_quota_reservations (user_id, request_id, task_id, status)
    VALUES (v_user_id, p_request_id, v_task_record.id, 'committed');

    -- 7. Outbox Kaydını Aynı Transaction'da Oluştur
    INSERT INTO public.sync_operations (
        user_id, task_id, operation_type, idempotency_key, state_version, desired_state, status
    )
    VALUES (
        v_user_id,
        v_task_record.id,
        'sync_task',
        'sync_' || v_task_record.id || '_v1',
        1,
        jsonb_build_object(
            'target_date', p_scheduled_date,
            'task_time', p_task_time,
            'duration_minutes', p_duration_minutes,
            'title', p_title
        ),
        'pending'
    )
    ON CONFLICT (user_id, idempotency_key) DO NOTHING;

    RETURN jsonb_build_object(
        'success', true,
        'task', to_jsonb(v_task_record),
        'idempotent', false
    );
END;
$$;

REVOKE ALL ON FUNCTION public.create_voice_task_with_quota FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_voice_task_with_quota TO authenticated;