-- WeeklyPulse Canonical Production Migration v18
-- Kapsam: Trust-Boundary Verification, Atomic Outbox Claiming, Revoke Compatibility Shortcut

-- 1. TABLO KISITLAMALARI VE PROFİL
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'check_weekly_tasks_mode') THEN
        ALTER TABLE public.weekly_tasks ADD CONSTRAINT check_weekly_tasks_mode CHECK (task_mode IN ('student', 'pro'));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'check_weekly_tasks_priority') THEN
        ALTER TABLE public.weekly_tasks ADD CONSTRAINT check_weekly_tasks_priority CHECK (priority IN ('Düşük', 'Orta', 'Yüksek', 'Kritik'));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'check_weekly_tasks_duration') THEN
        ALTER TABLE public.weekly_tasks ADD CONSTRAINT check_weekly_tasks_duration CHECK (duration_minutes BETWEEN 15 AND 480);
    END IF;
END $$;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS last_usage_week text;

-- 2. KARANTİNA VE ARŞİV TABLOLARI (Service-Role İzolasyonu)
CREATE TABLE IF NOT EXISTS public.sync_operations_quarantine (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    archive_id uuid,
    raw_payload jsonb,
    quarantine_reason text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.sync_operations_quarantine ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Service role and admins manage quarantine" ON public.sync_operations_quarantine;
CREATE POLICY "Service role and admins manage quarantine"
ON public.sync_operations_quarantine FOR ALL
TO service_role USING (true) WITH CHECK (true);

CREATE TABLE IF NOT EXISTS public.sync_operations_archive (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    original_operation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    task_id uuid,
    operation_type text NOT NULL,
    idempotency_key text,
    desired_state jsonb,
    status text,
    attempts integer,
    archived_at timestamptz NOT NULL DEFAULT now(),
    archive_reason text NOT NULL DEFAULT 'duplicate_resolution'
);

ALTER TABLE public.sync_operations_archive ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can only read own archived operations" ON public.sync_operations_archive;
CREATE POLICY "Users can only read own archived operations"
ON public.sync_operations_archive FOR SELECT
TO authenticated USING (auth.uid() = user_id);

-- 3. SYNC_OPERATIONS ANA TABLO VE UNIQUE KISITLAMALARI
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

ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS sync_operations_task_id_fkey;
ALTER TABLE public.sync_operations 
ADD CONSTRAINT sync_operations_task_id_fkey 
FOREIGN KEY (task_id) REFERENCES public.weekly_tasks(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_operations_user_idempotency
ON public.sync_operations (user_id, idempotency_key);

ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS unique_user_outbox_key;
ALTER TABLE public.sync_operations 
ADD CONSTRAINT unique_user_outbox_key UNIQUE USING INDEX idx_sync_operations_user_idempotency;

ALTER TABLE public.sync_operations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can only read their sync operations" ON public.sync_operations;
CREATE POLICY "Users can only read their sync operations"
ON public.sync_operations FOR SELECT
TO authenticated USING (auth.uid() = user_id);

-- 4. P1: ATOMİK OUTBOX CLAIM RPC (Multi-Device Lease Lock)
CREATE OR REPLACE FUNCTION public.claim_pending_delete_operations(
    p_limit integer DEFAULT 10,
    p_lease_seconds integer DEFAULT 60
)
RETURNS TABLE (
    id uuid,
    desired_state jsonb,
    attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH available_ops AS (
        SELECT s.id
        FROM public.sync_operations s
        WHERE s.user_id = v_user_id
          AND s.operation_type = 'delete'
          AND s.status IN ('pending', 'partial')
          AND (s.locked_until IS NULL OR s.locked_until < now())
          AND (s.next_retry_at IS NULL OR s.next_retry_at <= now())
        ORDER BY s.created_at ASC
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    )
    UPDATE public.sync_operations u
    SET status = 'processing',
        locked_until = now() + (p_lease_seconds || ' seconds')::interval,
        updated_at = now()
    FROM available_ops a
    WHERE u.id = a.id
    RETURNING u.id, u.desired_state, u.attempt_count;
END;
$$;

-- 5. P0: TRUST-BOUNDARY SIDE-EFFECT VERIFICATION RPC
CREATE OR REPLACE FUNCTION public.report_delete_side_effects(
    p_operation_id uuid,
    p_notification_status text,
    p_calendar_status text,
    p_verified_event_id text DEFAULT NULL,
    p_error_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_op record;
    v_is_calendar_verified boolean := false;
    v_is_notif_acknowledged boolean := false;
    v_expected_event_id text;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    SELECT * INTO v_op
    FROM public.sync_operations
    WHERE id = p_operation_id AND user_id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Operasyon bulunamadı.');
    END IF;

    IF v_op.operation_type <> 'delete' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_OPERATION_TYPE', 'message', 'Yalnızca silme operasyonları raporlanabilir.');
    END IF;

    IF v_op.status = 'completed' THEN
        RETURN jsonb_build_object('success', true, 'message', 'Operasyon zaten tamamlanmış.', 'idempotent_replay', true);
    END IF;

    v_expected_event_id := v_op.desired_state->>'calendar_event_id';

    -- Takvim Doğrulaması: Beklenen event yoksa veya dönen onay eşleşiyorsa
    IF v_expected_event_id IS NULL OR v_expected_event_id = '' OR p_calendar_status = 'skipped' THEN
        v_is_calendar_verified := true;
    ELSIF p_calendar_status = 'provider_verified' AND (p_verified_event_id = v_expected_event_id OR p_verified_event_id = 'not_found') THEN
        v_is_calendar_verified := true;
    END IF;

    -- Bildirim Doğrulaması: İstemci onay durumu
    IF (v_op.desired_state->>'notification_id') IS NULL OR p_notification_status IN ('client_acknowledged', 'skipped') THEN
        v_is_notif_acknowledged := true;
    END IF;

    IF v_is_calendar_verified AND v_is_notif_acknowledged THEN
        UPDATE public.sync_operations
        SET status = 'completed',
            locked_until = NULL,
            desired_state = jsonb_set(
                jsonb_set(desired_state, '{notification_status}', to_jsonb(p_notification_status)),
                '{calendar_status}', to_jsonb(p_calendar_status)
            ),
            updated_at = now(),
            last_error = NULL
        WHERE id = p_operation_id AND user_id = v_user_id;

        RETURN jsonb_build_object('success', true, 'status', 'completed');
    ELSE
        -- Doğrulanamayan durum: partial ve retryable olarak işaretle
        UPDATE public.sync_operations
        SET status = 'partial',
            locked_until = NULL,
            attempt_count = attempt_count + 1,
            next_retry_at = now() + (least(power(2, attempt_count) * 60, 3600) || ' seconds')::interval,
            last_error = coalesce(p_error_message, 'Dış side effect doğrulanamadı'),
            desired_state = jsonb_set(
                jsonb_set(desired_state, '{notification_status}', to_jsonb(p_notification_status)),
                '{calendar_status}', to_jsonb(p_calendar_status)
            ),
            updated_at = now()
        WHERE id = p_operation_id AND user_id = v_user_id;

        RETURN jsonb_build_object(
            'success', false,
            'status', 'partial',
            'code', 'SIDE_EFFECT_UNVERIFIED',
            'message', 'Dış sistem temizliği doğrulanamadı, yeniden denenecek.'
        );
    END IF;
END;
$$;

-- 6. P0: ESKİ SHORTCUT RPC'SİNİ KALDIR (REVOKE)
DROP FUNCTION IF EXISTS public.complete_delete_operation(uuid);

-- 7. KOTA VE MUTASYON RPC'LERİ (Korundu)
CREATE OR REPLACE FUNCTION public.delete_task_durable(
    p_task_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_task record;
    v_existing_op record;
    v_outbox_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    SELECT * INTO v_task
    FROM public.weekly_tasks
    WHERE id = p_task_id AND user_id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        SELECT * INTO v_existing_op
        FROM public.sync_operations
        WHERE user_id = v_user_id AND idempotency_key = 'delete_' || p_task_id::text;

        IF FOUND THEN
            RETURN jsonb_build_object('success', true, 'message', 'Görev silinmiş ve temizleme kuyruğunda.', 'idempotent_replay', true);
        END IF;

        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Görev bulunamadı.');
    END IF;

    INSERT INTO public.sync_operations (
        task_id,
        user_id,
        operation_type,
        idempotency_key,
        desired_state,
        state_version,
        status
    ) VALUES (
        NULL,
        v_user_id,
        'delete',
        'delete_' || p_task_id::text,
        jsonb_build_object(
            'deleted_task_id', p_task_id,
            'notification_id', v_task.notification_id,
            'calendar_id', v_task.calendar_id,
            'calendar_event_id', v_task.calendar_event_id,
            'notification_status', 'pending',
            'calendar_status', 'pending'
        ),
        v_task.version,
        'pending'
    ) ON CONFLICT (user_id, idempotency_key) DO UPDATE
    SET desired_state = EXCLUDED.desired_state, updated_at = now()
    RETURNING id INTO v_outbox_id;

    IF v_outbox_id IS NULL THEN
        RAISE EXCEPTION 'Delete outbox kaydı oluşturulamadı.';
    END IF;

    DELETE FROM public.weekly_tasks
    WHERE id = p_task_id AND user_id = v_user_id;

    RETURN jsonb_build_object('success', true, 'message', 'Görev silindi ve temizleme kuyruğuna alındı.');
END;
$$;

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
        'task_mode', v_updated_task.task_mode,
        'scheduled_date', p_scheduled_date,
        'week_start_date', p_week_start_date,
        'day_index', p_day_index,
        'task_time', p_task_time,
        'duration_minutes', p_duration_minutes,
        'priority', p_priority,
        'deadline', p_deadline,
        'reminder_time', p_reminder_time,
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

-- 8. ROLE-BASED ALLOWLIST (P0: complete_delete_operation kaldırıldı)
REVOKE ALL ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.delete_task_durable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_task_durable(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.claim_pending_delete_operations(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_pending_delete_operations(integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.report_delete_side_effects(uuid, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.report_delete_side_effects(uuid, text, text, text, text) TO authenticated;