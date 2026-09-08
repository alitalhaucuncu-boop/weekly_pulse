-- 1. sync_operations Tablosu (Strict Constraint, Monotonic Versioning & Idempotency)
CREATE TABLE IF NOT EXISTS public.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    task_id uuid,
    operation_type text NOT NULL DEFAULT 'sync_task',
    idempotency_key text NOT NULL,
    desired_state jsonb NOT NULL,
    state_version int NOT NULL DEFAULT 1,
    status text NOT NULL DEFAULT 'pending',
    attempt_count int NOT NULL DEFAULT 0,
    max_attempts int NOT NULL DEFAULT 5,
    next_retry_at timestamptz NOT NULL DEFAULT now(),
    locked_until timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chk_sync_op_status CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'user_action_required', 'cancelled')),
    CONSTRAINT sync_operations_user_idemp_unique UNIQUE (user_id, idempotency_key)
);

-- Canlı Veritabanı için Idempotent FK Yükseltmesi (ON DELETE SET NULL Güvencesi)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'sync_operations_task_id_fkey' 
          AND table_name = 'sync_operations'
    ) THEN
        ALTER TABLE public.sync_operations DROP CONSTRAINT sync_operations_task_id_fkey;
    END IF;
    
    ALTER TABLE public.sync_operations 
    ADD CONSTRAINT sync_operations_task_id_fkey 
    FOREIGN KEY (task_id) REFERENCES public.weekly_tasks(id) ON DELETE SET NULL;
END $$;

ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS state_version int NOT NULL DEFAULT 1;

ALTER TABLE public.sync_operations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sync_operations_user_policy ON public.sync_operations;
CREATE POLICY sync_operations_user_policy ON public.sync_operations
    FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE INDEX IF NOT EXISTS idx_sync_operations_claim ON public.sync_operations (user_id, status, next_retry_at, locked_until);

-- 2. Atomik Normal Görev Ekleme RPC'si (Direct Insert Yerine)
CREATE OR REPLACE FUNCTION public.create_task_with_outbox(
    p_title text,
    p_category text,
    p_day_index int,
    p_scheduled_date text,
    p_week_start_date text,
    p_task_mode text,
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
    v_task_record public.weekly_tasks%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    INSERT INTO public.weekly_tasks (
        user_id, title, category, day_index, scheduled_date, week_start_date,
        task_mode, task_time, duration_minutes, priority, deadline, reminder_time,
        version, sync_status
    )
    VALUES (
        v_user_id, p_title, p_category, p_day_index, p_scheduled_date, p_week_start_date,
        p_task_mode, p_task_time, p_duration_minutes, p_priority, p_deadline, p_reminder_time,
        1, 'pending'
    )
    RETURNING * INTO v_task_record;

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
        'task', to_jsonb(v_task_record)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.create_task_with_outbox FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_task_with_outbox TO authenticated;

-- 3. Atomik Task Mutasyon ve Outbox Kaydı (Server-Authoritative Versioning)
CREATE OR REPLACE FUNCTION public.save_task_mutation(
    p_task_id uuid,
    p_title text,
    p_category text,
    p_day_index int,
    p_scheduled_date text,
    p_week_start_date text,
    p_task_time text,
    p_duration_minutes int,
    p_priority text,
    p_deadline timestamptz,
    p_reminder_time text,
    p_is_completed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_new_version int;
    v_task_record public.weekly_tasks%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    UPDATE public.weekly_tasks
    SET title = p_title,
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
        sync_status = 'pending',
        version = version + 1,
        updated_at = now()
    WHERE id = p_task_id AND user_id = v_user_id
    RETURNING * INTO v_task_record;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Görev bulunamadı.');
    END IF;

    v_new_version := v_task_record.version;

    -- Outbox kaydını aynı transaction içinde atomik oluştur
    INSERT INTO public.sync_operations (
        user_id,
        task_id,
        operation_type,
        idempotency_key,
        state_version,
        desired_state,
        status,
        last_error
    )
    VALUES (
        v_user_id,
        p_task_id,
        'sync_task',
        'sync_' || p_task_id || '_v' || v_new_version,
        v_new_version,
        jsonb_build_object(
            'target_date', p_scheduled_date,
            'task_time', p_task_time,
            'duration_minutes', p_duration_minutes,
            'title', p_title
        ),
        'pending'
    )
    ON CONFLICT (user_id, idempotency_key) DO UPDATE
    SET desired_state = EXCLUDED.desired_state,
        status = 'pending',
        updated_at = now()
    WHERE sync_operations.status != 'processing';

    RETURN jsonb_build_object(
        'success', true,
        'version', v_new_version,
        'task', to_jsonb(v_task_record)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.save_task_mutation FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_task_mutation TO authenticated;

-- 4. Atomik Görev Silme ve Durable Outbox RPC'si
CREATE OR REPLACE FUNCTION public.delete_task_durable(p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_task public.weekly_tasks%ROWTYPE;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    SELECT * INTO v_task FROM public.weekly_tasks WHERE id = p_task_id AND user_id = v_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Görev bulunamadı.');
    END IF;

    IF v_task.calendar_event_id IS NOT NULL OR v_task.notification_id IS NOT NULL THEN
        INSERT INTO public.sync_operations (
            user_id,
            task_id,
            operation_type,
            idempotency_key,
            state_version,
            desired_state,
            status
        )
        VALUES (
            v_user_id,
            NULL,
            'delete_task',
            'delete_' || p_task_id,
            v_task.version,
            jsonb_build_object(
                'calendar_id', v_task.calendar_id,
                'calendar_event_id', v_task.calendar_event_id,
                'notification_id', v_task.notification_id
            ),
            'pending'
        )
        ON CONFLICT (user_id, idempotency_key) DO NOTHING;
    END IF;

    DELETE FROM public.weekly_tasks WHERE id = p_task_id AND user_id = v_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_task_durable FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_task_durable TO authenticated;

-- 5. Atomik Outbox Claim RPC
CREATE OR REPLACE FUNCTION public.claim_sync_operations(
    p_limit int DEFAULT 10,
    p_lock_seconds int DEFAULT 60
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_safe_limit int;
    v_safe_lock_seconds int;
    v_claimed jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    v_safe_limit := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
    v_safe_lock_seconds := LEAST(GREATEST(COALESCE(p_lock_seconds, 60), 15), 300);

    WITH available_ops AS (
        SELECT id
        FROM public.sync_operations
        WHERE user_id = v_user_id
          AND attempt_count < max_attempts
          AND (
              (status IN ('pending', 'failed') AND (next_retry_at IS NULL OR next_retry_at <= now()))
              OR
              (status = 'processing' AND locked_until IS NOT NULL AND locked_until <= now())
          )
        ORDER BY created_at ASC
        LIMIT v_safe_limit
        FOR UPDATE SKIP LOCKED
    ),
    updated_ops AS (
        UPDATE public.sync_operations o
        SET status = 'processing',
            attempt_count = o.attempt_count + 1,
            locked_until = now() + (v_safe_lock_seconds || ' seconds')::interval,
            updated_at = now()
        FROM available_ops a
        WHERE o.id = a.id
        RETURNING o.id, o.task_id, o.operation_type, o.desired_state, o.state_version, o.attempt_count
    )
    SELECT coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb)
    INTO v_claimed
    FROM updated_ops u;

    RETURN v_claimed;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_sync_operations(int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_sync_operations(int, int) TO authenticated;

-- 6. Version-Guarded Fail-Closed Complete Sync Operation RPC
CREATE OR REPLACE FUNCTION public.complete_sync_operation(
    p_operation_id uuid,
    p_state_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_rows_updated int;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    UPDATE public.sync_operations
    SET status = 'completed',
        locked_until = NULL,
        last_error = NULL,
        updated_at = now()
    WHERE id = p_operation_id 
      AND user_id = v_user_id 
      AND status = 'processing'
      AND state_version = p_state_version;

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Stale worker veya operasyon işlenir durumda değil.');
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.complete_sync_operation(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_sync_operation(uuid, int) TO authenticated;

-- 7. Version-Guarded Fail-Closed Fail Sync Operation RPC
CREATE OR REPLACE FUNCTION public.fail_sync_operation(
    p_operation_id uuid,
    p_state_version int,
    p_error_message text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_attempts int;
    v_max int;
    v_rows_updated int;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    SELECT attempt_count, max_attempts INTO v_attempts, v_max
    FROM public.sync_operations
    WHERE id = p_operation_id 
      AND user_id = v_user_id 
      AND status = 'processing'
      AND state_version = p_state_version;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Stale worker veya operasyon bulunamadı.');
    END IF;

    IF v_attempts >= v_max THEN
        UPDATE public.sync_operations
        SET status = 'user_action_required',
            locked_until = NULL,
            last_error = p_error_message,
            updated_at = now()
        WHERE id = p_operation_id AND user_id = v_user_id;
    ELSE
        UPDATE public.sync_operations
        SET status = 'failed',
            locked_until = NULL,
            next_retry_at = now() + (interval '15 seconds' * power(2, v_attempts)),
            last_error = p_error_message,
            updated_at = now()
        WHERE id = p_operation_id AND user_id = v_user_id;
    END IF;

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Durum güncellenemedi.');
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.fail_sync_operation(uuid, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fail_sync_operation(uuid, int, text) TO authenticated;

-- 8. Guarded Fail-Closed Cancel Sync Operation RPC
CREATE OR REPLACE FUNCTION public.cancel_sync_operation(
    p_operation_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_rows_updated int;
BEGIN
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Yetkisiz işlem.');
    END IF;

    UPDATE public.sync_operations
    SET status = 'cancelled',
        locked_until = NULL,
        last_error = p_reason,
        updated_at = now()
    WHERE id = p_operation_id 
      AND user_id = v_user_id 
      AND status = 'processing';

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Operasyon iptal edilemedi veya işlenir durumda değil.');
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_sync_operation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_sync_operation(uuid, text) TO authenticated;