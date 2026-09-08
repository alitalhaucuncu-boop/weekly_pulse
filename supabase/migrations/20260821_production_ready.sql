-- WeeklyPulse Canonical Production Migration
-- Şema, Kısıtlamalar, Temizlik ve Çekirdek RPC'ler

-- 1. ESKİ FONKSİYONLARI VE POLİTİKALARI TEMİZLE (Overload Ambiguity Önleme)
DROP FUNCTION IF EXISTS public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean);
DROP FUNCTION IF EXISTS public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer);
DROP FUNCTION IF EXISTS public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text);
DROP FUNCTION IF EXISTS public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text);

-- 2. TABLO KISITLAMALARI (CHECK CONSTRAINTS)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'check_weekly_tasks_mode'
    ) THEN
        ALTER TABLE public.weekly_tasks
        ADD CONSTRAINT check_weekly_tasks_mode CHECK (task_mode IN ('student', 'pro'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'check_weekly_tasks_priority'
    ) THEN
        ALTER TABLE public.weekly_tasks
        ADD CONSTRAINT check_weekly_tasks_priority CHECK (priority IN ('Düşük', 'Orta', 'Yüksek', 'Kritik'));
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'check_weekly_tasks_duration'
    ) THEN
        ALTER TABLE public.weekly_tasks
        ADD CONSTRAINT check_weekly_tasks_duration CHECK (duration_minutes BETWEEN 15 AND 480);
    END IF;
END $$;

-- 3. SYNC_OPERATIONS ŞEMA & POLİTİKA GÜVENCESİ (P0-03 & P0-06)
CREATE TABLE IF NOT EXISTS public.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    task_id uuid REFERENCES public.weekly_tasks(id) ON DELETE CASCADE,
    operation_type text NOT NULL,
    idempotency_key text NOT NULL UNIQUE,
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

ALTER TABLE public.sync_operations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can manage their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "sync_operations_user_policy" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can insert their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can update their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can only read their sync operations" ON public.sync_operations;

-- Kesin kural: Authenticated istemci yalnızca SELECT yapabilir
CREATE POLICY "Users can only read their sync operations"
ON public.sync_operations FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 4. CANONICAL save_task_mutation RPC (P0-01, P0-04, P0-05)
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
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    -- Süre ve başlık doğrulaması (DB constraint 15-480 ile tam uyumlu)
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

    -- Compare-and-Swap Kontrolü
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

    -- sync_operations Şemasına Birebir Uyumlu Outbox Insert (desired_state & idempotency_key)
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
    ) ON CONFLICT (idempotency_key) DO NOTHING;

    RETURN jsonb_build_object(
        'success', true,
        'version', v_updated_task.version,
        'task', to_jsonb(v_updated_task)
    );
END;
$$;

-- 5. CANONICAL create_voice_task_with_quota RPC (P0-02 & P0-06)
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
    v_clamped_duration integer;
    v_existing_task record;
    v_idempotency_key text;
    v_desired_state jsonb;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum açılmamış.');
    END IF;

    -- İdempotensi Kontrolü: Aynı p_request_id daha önce işlendiyse görevi dön
    SELECT * INTO v_existing_task 
    FROM public.sync_operations 
    WHERE user_id = v_user_id AND idempotency_key = p_request_id;

    IF FOUND AND v_existing_task.task_id IS NOT NULL THEN
        SELECT * INTO v_new_task FROM public.weekly_tasks WHERE id = v_existing_task.task_id;
        RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task), 'idempotent_replay', true);
    END IF;

    v_effective_mode := CASE WHEN p_task_mode = 'pro' THEN 'pro' ELSE 'student' END;
    v_clamped_duration := LEAST(GREATEST(p_duration_minutes, 15), 480);

    SELECT is_premium, voice_usage INTO v_is_premium, v_voice_usage
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kullanıcı profili bulunamadı.');
    END IF;

    IF NOT v_is_premium AND v_voice_usage >= 3 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Haftalık sesli komut kotanız doldu.');
    END IF;

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
        v_clamped_duration,
        p_priority,
        p_deadline,
        p_reminder_time,
        false,
        1,
        'pending'
    ) RETURNING * INTO v_new_task;

    v_task_id := v_new_task.id;
    v_idempotency_key := p_request_id;
    v_desired_state := jsonb_build_object(
        'task_id', v_task_id,
        'title', trim(p_title),
        'scheduled_date', p_scheduled_date,
        'task_time', p_task_time,
        'duration_minutes', v_clamped_duration,
        'task_mode', v_effective_mode,
        'version', 1
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
        v_task_id,
        v_user_id,
        'create',
        v_idempotency_key,
        v_desired_state,
        1,
        'pending'
    ) ON CONFLICT (idempotency_key) DO NOTHING;

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