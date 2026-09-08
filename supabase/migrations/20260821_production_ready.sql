-- WeeklyPulse Canonical Production Schema & RPCs
-- P0-01, P0-02, P0-06 Düzeltmeleri

-- 1. Tablo Kısıtlamaları (Check Constraints)
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
END $$;

-- 2. Outbox Tablosu RLS İzolasyonu (P0-06): İstemci doğrudan INSERT/UPDATE/DELETE yapamaz
DROP POLICY IF EXISTS "Users can manage their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can insert their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can update their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "Users can only read their sync operations" ON public.sync_operations;

CREATE POLICY "Users can only read their sync operations"
ON public.sync_operations FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3. Canonical save_task_mutation RPC (P0-01: Compare-and-Swap / Optimistic Concurrency)
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
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    IF trim(p_title) = '' OR length(p_title) > 200 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TITLE', 'message', 'Geçersiz görev başlığı.');
    END IF;

    IF p_duration_minutes <= 0 OR p_duration_minutes > 1440 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DURATION', 'message', 'Geçersiz süre.');
    END IF;

    SELECT * INTO v_current_task
    FROM public.weekly_tasks
    WHERE id = p_task_id AND user_id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Görev bulunamadı.');
    END IF;

    -- Versiyon Karşılaştırması (CAS)
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

    INSERT INTO public.sync_operations (
        task_id,
        user_id,
        operation_type,
        status,
        payload
    ) VALUES (
        p_task_id,
        v_user_id,
        'update',
        'pending',
        jsonb_build_object(
            'task_id', p_task_id,
            'title', p_title,
            'is_completed', p_is_completed,
            'version', v_updated_task.version
        )
    );

    RETURN jsonb_build_object(
        'success', true,
        'version', v_updated_task.version,
        'task', to_jsonb(v_updated_task)
    );
END;
$$;

-- 4. Canonical create_voice_task_with_quota RPC (P0-02: Mode & Quota Entegrasyonu)
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
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum açılmamış.');
    END IF;

    v_effective_mode := CASE WHEN p_task_mode = 'pro' THEN 'pro' ELSE 'student' END;

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
        status,
        payload
    ) VALUES (
        v_task_id,
        v_user_id,
        'create',
        'pending',
        jsonb_build_object(
            'task_id', v_task_id,
            'title', p_title,
            'scheduled_date', p_scheduled_date,
            'task_time', p_task_time,
            'duration_minutes', p_duration_minutes,
            'task_mode', v_effective_mode
        )
    );

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