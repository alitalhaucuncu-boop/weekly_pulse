-- 1. MEVCUT CANLI TABLOLARIN TÜM EKSİK KOLONLARINI EKLE (P0-02)
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS last_usage_week text;

CREATE TABLE IF NOT EXISTS public.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    task_id uuid REFERENCES public.weekly_tasks(id) ON DELETE SET NULL,
    operation_type text NOT NULL,
    idempotency_key text NOT NULL,
    desired_state jsonb NOT NULL DEFAULT '{}'::jsonb,
    state_version integer NOT NULL DEFAULT 1,
    status text NOT NULL DEFAULT 'pending',
    attempt_count integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 5,
    next_retry_at timestamptz DEFAULT now(),
    locked_until timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS idempotency_key text;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS desired_state jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS state_version integer NOT NULL DEFAULT 1;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'pending';
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS attempt_count integer NOT NULL DEFAULT 0;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS max_attempts integer NOT NULL DEFAULT 5;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS next_retry_at timestamptz DEFAULT now();
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS locked_until timestamptz;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS last_error text;
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- FK'yı SET NULL olarak güncelle
ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS sync_operations_task_id_fkey;
ALTER TABLE public.sync_operations 
ADD CONSTRAINT sync_operations_task_id_fkey 
FOREIGN KEY (task_id) REFERENCES public.weekly_tasks(id) ON DELETE SET NULL;

-- 2. DETERMINISTIC UNIQUE CONSTRAINT MIGRATION (P0-03)
-- Varsa eski duplicate kayıtları temizle
DELETE FROM public.sync_operations a USING public.sync_operations b
WHERE a.id < b.id 
  AND a.user_id = b.user_id 
  AND a.idempotency_key = b.idempotency_key;

-- Kataloğu tarayıp idempotency_key üzerindeki tüm eski constraint'leri temizle
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT conname 
        FROM pg_constraint 
        WHERE conrelid = 'public.sync_operations'::regclass 
          AND contype = 'u'
    ) LOOP
        EXECUTE 'ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS ' || quote_ident(r.conname);
    END LOOP;
END $$;

ALTER TABLE public.sync_operations 
ADD CONSTRAINT unique_user_outbox_key UNIQUE (user_id, idempotency_key);

-- RLS İzolasyonu
ALTER TABLE public.sync_operations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can only read their sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can manage their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "sync_operations_user_policy" ON public.sync_operations;

CREATE POLICY "Users can only read their sync operations"
ON public.sync_operations FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3. AI QUOTA TABLOSU VE STATUS CHECK CONSTRAINT
CREATE TABLE IF NOT EXISTS public.ai_quota_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    request_id text NOT NULL,
    status text NOT NULL DEFAULT 'consumed',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_user_ai_request UNIQUE (user_id, request_id)
);

ALTER TABLE public.ai_quota_logs ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'consumed';
ALTER TABLE public.ai_quota_logs DROP CONSTRAINT IF EXISTS check_ai_log_status;
ALTER TABLE public.ai_quota_logs ADD CONSTRAINT check_ai_log_status CHECK (status IN ('consumed', 'refunded'));

ALTER TABLE public.ai_quota_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read own ai quota logs" ON public.ai_quota_logs;
CREATE POLICY "Users can read own ai quota logs"
ON public.ai_quota_logs FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 4. DEADLOCK KORUMALI VE KESİN KİLİT SIRALI CANONICAL RPC'LER (P0-01)

-- save_task_mutation
CREATE OR REPLACE FUNCTION public.save_task_mutation(
    p_task_id uuid,
    p_title text,
    p_category text,
    p_day_index integer,
    p_scheduled_date text,
    p_week_start_date text,
    p_task_time text,
    p_duration_minutes integer,
    p_priority text,
    p_deadline timestamptz DEFAULT NULL,
    p_reminder_time text DEFAULT '1 Saat Önce',
    p_is_completed boolean DEFAULT false,
    p_expected_version integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_current_task record;
    v_updated_task record;
    v_idempotency_key text;
    v_desired_state jsonb;
    v_outbox_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    IF trim(p_title) = '' OR length(p_title) > 200 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TITLE', 'message', 'Geçersiz görev başlığı.');
    END IF;

    IF p_duration_minutes < 15 OR p_duration_minutes > 480 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DURATION', 'message', 'Görev süresi 15 ile 480 dakika arasında olmalıdır.');
    END IF;

    SELECT * INTO v_current_task
    FROM public.weekly_tasks
    WHERE id = p_task_id AND user_id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Görev bulunamadı.');
    END IF;

    IF p_expected_version IS NOT NULL AND v_current_task.version <> p_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'VERSION_CONFLICT',
            'message', 'Bu görev başka bir cihazda değiştirilmiş.',
            'server_version', v_current_task.version,
            'current_task', to_jsonb(v_current_task)
        );
    END IF;

    UPDATE public.weekly_tasks
    SET
        title = trim(p_title),
        category = p_category,
        day_index = p_day_index,
        scheduled_date = p_scheduled_date,
        week_start_date = p_week_start_date,
        task_time = p_task_time,
        duration_minutes = p_duration_minutes,
        priority = p_priority,
        deadline = p_deadline,
        reminder_time = p_reminder_time,
        is_completed = p_is_completed,
        version = v_current_task.version + 1,
        sync_status = 'pending'
    WHERE id = p_task_id AND user_id = v_user_id
    RETURNING * INTO v_updated_task;

    v_idempotency_key := 'mutation_' || p_task_id::text || '_' || v_updated_task.version::text;
    v_desired_state := jsonb_build_object(
        'task_id', p_task_id,
        'title', trim(p_title),
        'category', p_category,
        'scheduled_date', p_scheduled_date,
        'task_time', p_task_time,
        'duration_minutes', p_duration_minutes,
        'is_completed', p_is_completed,
        'version', v_updated_task.version
    );

    INSERT INTO public.sync_operations (
        task_id,
        user_id,
        operation_type,
        idempotency_key,
        desired_state,
        state_version,
        status
    ) VALUES (
        p_task_id,
        v_user_id,
        'update',
        v_idempotency_key,
        v_desired_state,
        v_updated_task.version,
        'pending'
    ) ON CONFLICT (user_id, idempotency_key) DO UPDATE
    SET desired_state = EXCLUDED.desired_state, updated_at = now()
    RETURNING id INTO v_outbox_id;

    IF v_outbox_id IS NULL THEN
        RAISE EXCEPTION 'Outbox kaydı oluşturulamadı.';
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'version', v_updated_task.version,
        'task', to_jsonb(v_updated_task)
    );
END;
$$;

-- create_voice_task_with_quota (Süre clamp edilmez, katı doğrulanır - P1-04)
CREATE OR REPLACE FUNCTION public.create_voice_task_with_quota(
    p_request_id text,
    p_title text,
    p_category text,
    p_day_index integer,
    p_scheduled_date text,
    p_week_start_date text,
    p_task_time text,
    p_duration_minutes integer,
    p_priority text,
    p_deadline timestamptz DEFAULT NULL,
    p_reminder_time text DEFAULT '1 Saat Önce',
    p_task_mode text DEFAULT 'student'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_task_id uuid;
    v_new_task record;
    v_is_premium boolean;
    v_voice_usage integer;
    v_effective_mode text;
    v_existing_task record;
    v_current_week text;
    v_last_usage_week text;
    v_outbox_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum açılmamış.');
    END IF;

    IF trim(p_request_id) = '' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST_ID', 'message', 'Geçersiz istek kimliği.');
    END IF;

    IF p_duration_minutes < 15 OR p_duration_minutes > 480 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DURATION', 'message', 'Sesli görev süresi 15 ile 480 dakika arasında olmalıdır.');
    END IF;

    -- 1. ÖNCE PROFİLİ KİLİTLE
    SELECT is_premium, voice_usage, last_usage_week 
    INTO v_is_premium, v_voice_usage, v_last_usage_week
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kullanıcı profili bulunamadı.');
    END IF;

    -- 2. KİLİTTEN SONRA İDEMPOTENSİ KONTROLÜ
    SELECT * INTO v_existing_task 
    FROM public.sync_operations 
    WHERE user_id = v_user_id AND idempotency_key = p_request_id;

    IF FOUND AND v_existing_task.task_id IS NOT NULL THEN
        SELECT * INTO v_new_task FROM public.weekly_tasks WHERE id = v_existing_task.task_id;
        RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task), 'idempotent_replay', true);
    END IF;

    -- 3. HAFTALIK ROLLOVER
    v_current_week := to_char(now(), 'IYYY-IW');
    IF v_last_usage_week IS DISTINCT FROM v_current_week THEN
        v_voice_usage := 0;
        UPDATE public.profiles 
        SET voice_usage = 0, ai_usage = 0, last_usage_week = v_current_week 
        WHERE id = v_user_id;
    END IF;

    IF NOT v_is_premium AND v_voice_usage >= 3 THEN
        RETURN jsonb_build_object('success', false, 'code', 'LIMIT_EXCEEDED', 'message', 'Haftalık sesli komut kotanız doldu.');
    END IF;

    v_effective_mode := CASE WHEN p_task_mode = 'pro' THEN 'pro' ELSE 'student' END;

    INSERT INTO public.weekly_tasks (
        user_id,
        title,
        category,
        day_index,
        scheduled_date,
        week_start_date,
        task_mode,
        task_time,
        duration_minutes,
        priority,
        deadline,
        reminder_time,
        is_completed,
        version,
        sync_status
    ) VALUES (
        v_user_id,
        trim(p_title),
        p_category,
        p_day_index,
        p_scheduled_date,
        p_week_start_date,
        v_effective_mode,
        p_task_time,
        p_duration_minutes,
        p_priority,
        p_deadline,
        p_reminder_time,
        false,
        1,
        'pending'
    ) RETURNING * INTO v_new_task;

    v_task_id := v_new_task.id;

    INSERT INTO public.sync_operations (
        task_id,
        user_id,
        operation_type,
        idempotency_key,
        desired_state,
        state_version,
        status
    ) VALUES (
        v_task_id,
        v_user_id,
        'create',
        p_request_id,
        jsonb_build_object(
            'task_id', v_task_id,
            'title', trim(p_title),
            'scheduled_date', p_scheduled_date,
            'task_time', p_task_time,
            'duration_minutes', p_duration_minutes,
            'task_mode', v_effective_mode,
            'version', 1
        ),
        1,
        'pending'
    ) RETURNING id INTO v_outbox_id;

    IF v_outbox_id IS NULL THEN
        RAISE EXCEPTION 'Sesli görev outbox kaydı oluşturulamadı.';
    END IF;

    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET voice_usage = voice_usage + 1
        WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'task', to_jsonb(v_new_task)
    );
END;
$$;

-- consume_ai_quota (Lock Order: Önce profile FOR UPDATE, sonra log)
CREATE OR REPLACE FUNCTION public.consume_ai_quota(
    p_request_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_is_premium boolean;
    v_ai_usage integer;
    v_existing_log record;
    v_current_week text;
    v_last_usage_week text;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum açılmamış.');
    END IF;

    IF trim(p_request_id) = '' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST_ID', 'message', 'Geçersiz istek kimliği.');
    END IF;

    -- 1. ÖNCE PROFİL KİLİTLENİR (Lock Order 1)
    SELECT is_premium, ai_usage, last_usage_week 
    INTO v_is_premium, v_ai_usage, v_last_usage_week
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Profil bulunamadı.');
    END IF;

    -- 2. KİLİTTEN SONRA LOG KONTROLÜ
    SELECT * INTO v_existing_log 
    FROM public.ai_quota_logs 
    WHERE user_id = v_user_id AND request_id = p_request_id;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'ai_usage', v_ai_usage,
            'is_premium', v_is_premium,
            'idempotent_replay', true
        );
    END IF;

    -- 3. HAFTALIK ROLLOVER
    v_current_week := to_char(now(), 'IYYY-IW');
    IF v_last_usage_week IS DISTINCT FROM v_current_week THEN
        v_ai_usage := 0;
        UPDATE public.profiles 
        SET ai_usage = 0, voice_usage = 0, last_usage_week = v_current_week 
        WHERE id = v_user_id;
    END IF;

    IF NOT v_is_premium AND v_ai_usage >= 1 THEN
        RETURN jsonb_build_object('success', false, 'code', 'LIMIT_EXCEEDED', 'message', 'Haftalık Akıllı Analiz kotanız doldu.');
    END IF;

    -- 4. LOG KAYDI (Lock Order 2)
    INSERT INTO public.ai_quota_logs (
        request_id,
        user_id,
        status,
        created_at
    ) VALUES (
        p_request_id,
        v_user_id,
        'consumed',
        now()
    );

    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET ai_usage = ai_usage + 1
        WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'ai_usage', CASE WHEN v_is_premium THEN 0 ELSE v_ai_usage + 1 END,
        'is_premium', v_is_premium
    );
END;
$$;

-- refund_ai_quota (P0-01 DEADLOCK ÇÖZÜMÜ: Önce profile FOR UPDATE, sonra log FOR UPDATE)
CREATE OR REPLACE FUNCTION public.refund_ai_quota(
    p_request_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_is_premium boolean;
    v_usage integer;
    v_log record;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum açılmamış.');
    END IF;

    -- 1. DEADLOCK ENGELLEMEK İÇİN ÖNCE PROFİL KİLİTLENİR (Lock Order 1)
    SELECT is_premium, ai_usage INTO v_is_premium, v_usage 
    FROM public.profiles 
    WHERE id = v_user_id 
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kullanıcı profili bulunamadı.');
    END IF;

    -- 2. ARDINDAN LOG SATIRI KİLİTLENİR (Lock Order 2)
    SELECT * INTO v_log
    FROM public.ai_quota_logs
    WHERE user_id = v_user_id AND request_id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'İade edilecek tüketim kaydı bulunamadı.');
    END IF;

    -- Yalnızca 'consumed' ise iade yap (P1-02)
    IF v_log.status <> 'consumed' THEN
        RETURN jsonb_build_object(
            'success', true, 
            'ai_usage', v_usage, 
            'message', 'Bu istek zaten iade edilmiş veya geçersiz durumda.'
        );
    END IF;

    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET ai_usage = GREATEST(0, ai_usage - 1)
        WHERE id = v_user_id
        RETURNING ai_usage INTO v_usage;
    ELSE
        v_usage := 0;
    END IF;

    UPDATE public.ai_quota_logs
    SET status = 'refunded'
    WHERE user_id = v_user_id AND request_id = p_request_id;

    RETURN jsonb_build_object(
        'success', true,
        'ai_usage', v_usage,
        'message', 'Kota başarıyla iade edildi.'
    );
END;
$$;

-- 5. FUNCTION GRANTS SINIRLANDIRMASI (P1-01)
REVOKE ALL ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.consume_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_ai_quota(text) TO authenticated;

REVOKE ALL ON FUNCTION public.refund_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_ai_quota(text) TO authenticated;