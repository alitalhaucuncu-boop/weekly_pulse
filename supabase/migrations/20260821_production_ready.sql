-- WeeklyPulse Canonical Production Migration v31 (Full Inventory & Parity)
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email text,
    is_premium boolean DEFAULT false,
    tier_name text DEFAULT 'Free',
    plan_id text DEFAULT 'free',
    voice_command_usage integer DEFAULT 0,
    ai_analysis_usage integer DEFAULT 0,
    last_reset_week text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.weekly_tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title text NOT NULL,
    category text NOT NULL,
    day_index integer NOT NULL,
    scheduled_date date NOT NULL,
    week_start_date date NOT NULL,
    task_mode text NOT NULL DEFAULT 'student',
    task_time text NOT NULL,
    duration_minutes integer NOT NULL,
    priority text NOT NULL DEFAULT 'Orta',
    deadline timestamptz,
    reminder_time text DEFAULT '1 Saat Önce',
    is_completed boolean DEFAULT false,
    version integer NOT NULL DEFAULT 1,
    sync_status text DEFAULT 'pending',
    notification_id integer,
    calendar_id text,
    calendar_event_id text,
    last_synced_at timestamptz,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid REFERENCES public.weekly_tasks(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    operation_type text NOT NULL,
    idempotency_key text NOT NULL,
    desired_state jsonb NOT NULL,
    state_version integer NOT NULL DEFAULT 1,
    status text NOT NULL DEFAULT 'pending',
    attempt_count integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 5,
    lease_token_hash text,
    locked_until timestamptz,
    next_retry_at timestamptz DEFAULT now(),
    last_error text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    CONSTRAINT sync_operations_user_idempotency_key UNIQUE (user_id, idempotency_key)
);

ALTER TABLE public.sync_operations ALTER COLUMN task_id DROP NOT NULL;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_operations ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
    DROP POLICY IF EXISTS "Users can manage their own profiles" ON public.profiles;
    CREATE POLICY "Users can manage their own profiles" ON public.profiles
        FOR ALL TO authenticated USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

    DROP POLICY IF EXISTS "Users can manage their own tasks" ON public.weekly_tasks;
    CREATE POLICY "Users can manage their own tasks" ON public.weekly_tasks
        FOR ALL TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

    DROP POLICY IF EXISTS "Users can view their own sync operations" ON public.sync_operations;
    CREATE POLICY "Users can view their own sync operations" ON public.sync_operations
        FOR SELECT TO authenticated USING (auth.uid() = user_id);
END $$;

-- RPCs
CREATE OR REPLACE FUNCTION public.sync_my_profile_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_profile record;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum bulunamadı.');
    END IF;

    SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
    IF NOT FOUND THEN
        INSERT INTO public.profiles (id, email)
        VALUES (v_user_id, auth.jwt()->>'email')
        RETURNING * INTO v_profile;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'is_premium', coalesce(v_profile.is_premium, false),
        'tier_name', coalesce(v_profile.tier_name, 'Free'),
        'plan_id', coalesce(v_profile.plan_id, 'free'),
        'voice_usage', coalesce(v_profile.voice_command_usage, 0),
        'ai_usage', coalesce(v_profile.ai_analysis_usage, 0)
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.consume_ai_quota(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_is_premium boolean;
    v_usage integer;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    SELECT is_premium, coalesce(ai_analysis_usage, 0) INTO v_is_premium, v_usage
    FROM public.profiles WHERE id = v_user_id;

    IF coalesce(v_is_premium, false) = false AND v_usage >= 1 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'QUOTA_EXCEEDED',
            'message', 'Haftalık 1 analiz kotanız doldu. Sınırsız analiz için Elit Kulübe katılabilirsiniz.'
        );
    END IF;

    IF coalesce(v_is_premium, false) = false THEN
        UPDATE public.profiles SET ai_analysis_usage = v_usage + 1 WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'ai_usage', v_usage + 1, 'is_premium', coalesce(v_is_premium, false));
END;
$$;

CREATE OR REPLACE FUNCTION public.refund_ai_quota(p_request_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_usage integer;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum bulunamadı.');
    END IF;

    SELECT coalesce(ai_analysis_usage, 0) INTO v_usage FROM public.profiles WHERE id = v_user_id;

    IF v_usage > 0 THEN
        UPDATE public.profiles SET ai_analysis_usage = v_usage - 1 WHERE id = v_user_id;
        v_usage := v_usage - 1;
    END IF;

    RETURN jsonb_build_object('success', true, 'ai_usage', v_usage);
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_my_subscription()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum bulunamadı.');
    END IF;

    UPDATE public.profiles
    SET is_premium = false, tier_name = 'Free', plan_id = 'free', updated_at = now()
    WHERE id = v_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_task_with_outbox(
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
    p_task_mode text DEFAULT 'student',
    p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_new_task record;
    v_idempotency_key text;
    v_existing_op record;
    v_task_start timestamptz;
    v_task_end timestamptz;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    IF p_request_id IS NOT NULL AND trim(p_request_id) <> '' THEN
        SELECT * INTO v_existing_op FROM public.sync_operations WHERE user_id = v_user_id AND idempotency_key = p_request_id;
        IF FOUND THEN
            SELECT * INTO v_new_task FROM public.weekly_tasks WHERE id = v_existing_op.task_id AND user_id = v_user_id;
            IF FOUND THEN
                RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task), 'idempotent_replay', true);
            END IF;
        END IF;
    END IF;

    IF trim(p_title) = '' OR length(p_title) > 200 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TITLE', 'message', 'Geçersiz görev başlığı.');
    END IF;

    IF p_duration_minutes < 15 OR p_duration_minutes > 480 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DURATION', 'message', 'Süre 15-480 dakika arasında olmalıdır.');
    END IF;

    IF p_day_index < 0 OR p_day_index > 6 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DAY_INDEX', 'message', 'Gün indeksi 0 ile 6 arasında olmalıdır.');
    END IF;

    IF p_task_mode NOT IN ('student', 'pro') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TASK_MODE', 'message', 'Mod yalnızca student veya pro olabilir.');
    END IF;

    IF p_priority NOT IN ('Düşük', 'Orta', 'Yüksek', 'Kritik') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_PRIORITY', 'message', 'Geçersiz öncelik seviyesi.');
    END IF;

    IF p_task_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TASK_TIME', 'message', 'Saat formatı HH:mm olmalıdır.');
    END IF;

    IF p_deadline IS NOT NULL THEN
        BEGIN
            v_task_start := (p_scheduled_date || ' ' || p_task_time || ':00')::timestamptz;
            v_task_end := v_task_start + (p_duration_minutes || ' minutes')::interval;
            IF v_task_end > p_deadline THEN
                RETURN jsonb_build_object('success', false, 'code', 'DEADLINE_EXCEEDED', 'message', 'Görev bitiş saati teslim tarihini geçemez.');
            END IF;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;

    INSERT INTO public.weekly_tasks (
        user_id, title, category, day_index, scheduled_date, week_start_date,
        task_mode, task_time, duration_minutes, priority, deadline, reminder_time,
        is_completed, version, sync_status
    ) VALUES (
        v_user_id, trim(p_title), p_category, p_day_index, p_scheduled_date::date, p_week_start_date::date,
        p_task_mode, p_task_time, p_duration_minutes, p_priority, p_deadline, p_reminder_time,
        false, 1, 'pending'
    ) RETURNING * INTO v_new_task;

    v_idempotency_key := coalesce(p_request_id, 'create_' || v_new_task.id::text || '_1');

    INSERT INTO public.sync_operations (
        task_id, user_id, operation_type, idempotency_key, desired_state, state_version, status
    ) VALUES (
        v_new_task.id, v_user_id, 'create', v_idempotency_key,
        jsonb_build_object(
            'task_id', v_new_task.id, 'title', v_new_task.title, 'category', v_new_task.category,
            'task_mode', v_new_task.task_mode, 'scheduled_date', v_new_task.scheduled_date::text,
            'week_start_date', v_new_task.week_start_date::text, 'day_index', v_new_task.day_index,
            'task_time', v_new_task.task_time, 'duration_minutes', v_new_task.duration_minutes,
            'priority', v_new_task.priority, 'deadline', v_new_task.deadline,
            'reminder_time', v_new_task.reminder_time, 'is_completed', false, 'version', 1
        ),
        1, 'pending'
    ) ON CONFLICT (user_id, idempotency_key) DO UPDATE SET desired_state = EXCLUDED.desired_state, updated_at = now();

    RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task));
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
    p_expected_version integer,
    p_deadline timestamptz DEFAULT NULL,
    p_reminder_time text DEFAULT '1 Saat Önce',
    p_is_completed boolean DEFAULT false,
    p_request_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_curr_task record;
    v_new_version integer;
    v_idempotency_key text;
    v_task_start timestamptz;
    v_task_end timestamptz;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    IF p_expected_version IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'VERSION_REQUIRED', 'message', 'Versiyon numarası zorunludur.');
    END IF;

    IF trim(p_title) = '' OR length(p_title) > 200 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TITLE', 'message', 'Geçersiz görev başlığı.');
    END IF;

    IF p_duration_minutes < 15 OR p_duration_minutes > 480 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DURATION', 'message', 'Süre 15-480 dakika arasında olmalıdır.');
    END IF;

    IF p_day_index < 0 OR p_day_index > 6 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DAY_INDEX', 'message', 'Gün indeksi 0 ile 6 arasında olmalıdır.');
    END IF;

    IF p_priority NOT IN ('Düşük', 'Orta', 'Yüksek', 'Kritik') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_PRIORITY', 'message', 'Geçersiz öncelik seviyesi.');
    END IF;

    IF p_task_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TASK_TIME', 'message', 'Saat formatı HH:mm olmalıdır.');
    END IF;

    IF p_deadline IS NOT NULL THEN
        BEGIN
            v_task_start := (p_scheduled_date || ' ' || p_task_time || ':00')::timestamptz;
            v_task_end := v_task_start + (p_duration_minutes || ' minutes')::interval;
            IF v_task_end > p_deadline THEN
                RETURN jsonb_build_object('success', false, 'code', 'DEADLINE_EXCEEDED', 'message', 'Görev bitiş saati teslim tarihini geçemez.');
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_DATE_FORMAT', 'message', 'Geçersiz tarih formatı.');
        END;
    END IF;

    SELECT * INTO v_curr_task FROM public.weekly_tasks WHERE id = p_task_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Görev bulunamadı.');
    END IF;

    IF v_curr_task.version <> p_expected_version THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'VERSION_CONFLICT',
            'message', 'Versiyon çakışması tespit edildi.',
            'server_version', v_curr_task.version
        );
    END IF;

    v_new_version := v_curr_task.version + 1;

    UPDATE public.weekly_tasks
    SET title = trim(p_title), category = p_category, day_index = p_day_index,
        scheduled_date = p_scheduled_date::date, week_start_date = p_week_start_date::date,
        task_time = p_task_time, duration_minutes = p_duration_minutes, priority = p_priority,
        deadline = p_deadline, reminder_time = p_reminder_time, is_completed = p_is_completed,
        version = v_new_version, sync_status = 'pending', updated_at = now()
    WHERE id = p_task_id AND user_id = v_user_id;

    v_idempotency_key := coalesce(p_request_id, 'mutation_' || p_task_id::text || '_' || v_new_version::text);

    INSERT INTO public.sync_operations (
        task_id, user_id, operation_type, idempotency_key, desired_state, state_version, status
    ) VALUES (
        p_task_id, v_user_id, 'update', v_idempotency_key,
        jsonb_build_object(
            'task_id', p_task_id, 'title', p_title, 'category', p_category, 'day_index', p_day_index,
            'scheduled_date', p_scheduled_date, 'week_start_date', p_week_start_date, 'task_time', p_task_time,
            'duration_minutes', p_duration_minutes, 'priority', p_priority, 'deadline', p_deadline,
            'reminder_time', p_reminder_time, 'is_completed', p_is_completed, 'version', v_new_version
        ),
        v_new_version, 'pending'
    ) ON CONFLICT (user_id, idempotency_key) DO UPDATE SET desired_state = EXCLUDED.desired_state, updated_at = now();

    RETURN jsonb_build_object('success', true, 'version', v_new_version);
END;
$$;

CREATE OR REPLACE FUNCTION public.claim_pending_delete_operations(
    p_limit integer DEFAULT 10,
    p_lease_seconds integer DEFAULT 60
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_raw_token text;
    v_token_hash text;
    v_claimed_rows jsonb;
    v_effective_limit integer;
    v_effective_lease integer;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    v_effective_limit := least(greatest(coalesce(p_limit, 10), 1), 100);
    v_effective_lease := least(greatest(coalesce(p_lease_seconds, 60), 10), 300);

    v_raw_token := encode(gen_random_bytes(16), 'hex');
    v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');

    WITH claimable AS (
        SELECT id
        FROM public.sync_operations
        WHERE user_id = v_user_id
          AND operation_type = 'delete'
          AND (
              status IN ('pending', 'partial')
              OR (status = 'processing' AND locked_until < now())
          )
          AND (next_retry_at IS NULL OR next_retry_at <= now())
        ORDER BY created_at ASC
        LIMIT v_effective_limit
        FOR UPDATE SKIP LOCKED
    ),
    updated AS (
        UPDATE public.sync_operations
        SET status = 'processing',
            lease_token_hash = v_token_hash,
            locked_until = now() + (v_effective_lease || ' seconds')::interval,
            attempt_count = attempt_count + 1,
            updated_at = now()
        WHERE id IN (SELECT id FROM claimable)
        RETURNING id, task_id, operation_type, desired_state, state_version, attempt_count, max_attempts
    )
    SELECT coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) INTO v_claimed_rows FROM updated u;

    RETURN jsonb_build_object(
        'success', true,
        'lease_token', v_raw_token,
        'operations', v_claimed_rows
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.report_delete_side_effects(
    p_operation_id uuid,
    p_lease_token text,
    p_notification_status text,
    p_calendar_status text,
    p_verified_event_id text DEFAULT NULL,
    p_error_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_op record;
    v_is_calendar_verified boolean := false;
    v_is_notif_acknowledged boolean := false;
    v_expected_event_id text;
    v_expected_notif_id text;
    v_incoming_hash text;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    IF p_notification_status NOT IN ('best_effort_client_ack', 'client_acknowledged', 'failed', 'skipped') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_SIDE_EFFECT_STATUS', 'message', 'Geçersiz bildirim statüsü.');
    END IF;

    IF p_calendar_status NOT IN ('provider_verified', 'provider_not_found', 'failed', 'skipped') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_SIDE_EFFECT_STATUS', 'message', 'Geçersiz takvim statüsü.');
    END IF;

    SELECT * INTO v_op FROM public.sync_operations WHERE id = p_operation_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Operasyon bulunamadı.');
    END IF;

    IF v_op.status = 'completed' THEN
        RETURN jsonb_build_object('success', true, 'message', 'Operasyon zaten tamamlanmış.', 'idempotent_replay', true);
    END IF;

    v_incoming_hash := encode(digest(p_lease_token, 'sha256'), 'hex');

    IF v_op.status <> 'processing' 
       OR v_op.locked_until IS NULL 
       OR v_op.locked_until < now() 
       OR v_op.lease_token_hash IS DISTINCT FROM v_incoming_hash THEN
        RETURN jsonb_build_object('success', false, 'code', 'LEASE_EXPIRED_OR_INVALID', 'message', 'Operasyon lease süresi dolmuş veya geçersiz token.');
    END IF;

    v_expected_event_id := v_op.desired_state->>'calendar_event_id';
    v_expected_notif_id := v_op.desired_state->>'notification_id';

    IF v_expected_event_id IS NULL OR v_expected_event_id = '' THEN
        v_is_calendar_verified := true;
    ELSIF p_calendar_status = 'provider_verified' AND p_verified_event_id = v_expected_event_id THEN
        v_is_calendar_verified := true;
    ELSIF p_calendar_status = 'provider_not_found' AND p_verified_event_id = 'not_found' THEN
        v_is_calendar_verified := true;
    ELSE
        v_is_calendar_verified := false;
    END IF;

    IF v_expected_notif_id IS NULL OR v_expected_notif_id = '' THEN
        v_is_notif_acknowledged := true;
    ELSIF p_notification_status IN ('best_effort_client_ack', 'client_acknowledged') THEN
        v_is_notif_acknowledged := true;
    ELSE
        v_is_notif_acknowledged := false;
    END IF;

    IF v_is_calendar_verified AND v_is_notif_acknowledged THEN
        UPDATE public.sync_operations
        SET status = 'completed', locked_until = NULL, lease_token_hash = NULL,
            desired_state = jsonb_set(
                jsonb_set(desired_state, '{notification_status}', to_jsonb(p_notification_status)),
                '{calendar_status}', to_jsonb(p_calendar_status)
            ),
            updated_at = now(), last_error = NULL
        WHERE id = p_operation_id AND user_id = v_user_id;

        RETURN jsonb_build_object('success', true, 'status', 'completed');
    ELSE
        IF v_op.attempt_count >= v_op.max_attempts THEN
            UPDATE public.sync_operations
            SET status = 'dead_letter', locked_until = NULL, lease_token_hash = NULL,
                last_error = coalesce(p_error_message, 'Maksimum deneme sınırına ulaşıldı (Dead Letter).'),
                updated_at = now()
            WHERE id = p_operation_id AND user_id = v_user_id;

            RETURN jsonb_build_object('success', false, 'status', 'dead_letter', 'code', 'MAX_ATTEMPTS_EXCEEDED');
        ELSE
            UPDATE public.sync_operations
            SET status = 'partial', locked_until = NULL, lease_token_hash = NULL,
                next_retry_at = now() + (least(power(2, attempt_count) * 60, 3600) || ' seconds')::interval,
                last_error = coalesce(p_error_message, 'Dış yan etki doğrulanamadı'),
                desired_state = jsonb_set(
                    jsonb_set(desired_state, '{notification_status}', to_jsonb(p_notification_status)),
                    '{calendar_status}', to_jsonb(p_calendar_status)
                ),
                updated_at = now()
            WHERE id = p_operation_id AND user_id = v_user_id;

            RETURN jsonb_build_object('success', false, 'status', 'partial', 'code', 'SIDE_EFFECT_UNVERIFIED');
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_task_durable(p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_task record;
    v_idempotency_key text;
    v_task_version integer := 1;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    SELECT * INTO v_task FROM public.weekly_tasks WHERE id = p_task_id AND user_id = v_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', true, 'message', 'Görev zaten silinmiş.', 'idempotent_replay', true);
    END IF;

    v_task_version := coalesce(v_task.version, 1);
    v_idempotency_key := 'delete_' || p_task_id::text || '_' || v_task_version::text;

    INSERT INTO public.sync_operations (
        task_id, user_id, operation_type, idempotency_key, desired_state, state_version, status
    ) VALUES (
        p_task_id, v_user_id, 'delete', v_idempotency_key,
        jsonb_build_object(
            'task_id', p_task_id,
            'notification_id', v_task.notification_id,
            'calendar_id', v_task.calendar_id,
            'calendar_event_id', v_task.calendar_event_id
        ),
        v_task_version, 'pending'
    ) ON CONFLICT (user_id, idempotency_key) DO NOTHING;

    DELETE FROM public.weekly_tasks WHERE id = p_task_id AND user_id = v_user_id;

    RETURN jsonb_build_object('success', true, 'message', 'Görev silindi.');
END;
$$;

CREATE OR REPLACE FUNCTION public.create_voice_task_with_quota(
    p_request_id text,
    p_title text,
    p_category text,
    p_day_index integer,
    p_scheduled_date text,
    p_week_start_date text,
    p_task_mode text,
    p_task_time text,
    p_duration_minutes integer,
    p_priority text,
    p_deadline timestamptz DEFAULT NULL,
    p_reminder_time text DEFAULT '1 Saat Önce'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_profile record;
    v_new_task record;
    v_clean_title text;
    v_existing_op record;
    v_task_start timestamptz;
    v_task_end timestamptz;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum bulunamadı.');
    END IF;

    IF p_request_id IS NOT NULL AND trim(p_request_id) <> '' THEN
        SELECT * INTO v_existing_op 
        FROM public.sync_operations 
        WHERE user_id = v_user_id AND idempotency_key = p_request_id;

        IF FOUND THEN
            SELECT * INTO v_new_task 
            FROM public.weekly_tasks 
            WHERE id = v_existing_op.task_id AND user_id = v_user_id;

            IF FOUND THEN
                RETURN jsonb_build_object(
                    'success', true,
                    'task', to_jsonb(v_new_task),
                    'idempotent_replay', true
                );
            END IF;
        END IF;
    END IF;

    v_clean_title := trim(coalesce(p_title, ''));
    IF v_clean_title = '' OR length(v_clean_title) > 200 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TITLE', 'message', 'Geçersiz sesli plan başlığı.');
    END IF;

    IF p_duration_minutes < 15 OR p_duration_minutes > 480 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DURATION', 'message', 'Süre 15-480 dakika arasında olmalıdır.');
    END IF;

    IF p_day_index < 0 OR p_day_index > 6 THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_DAY_INDEX', 'message', 'Gün indeksi 0 ile 6 arasında olmalıdır.');
    END IF;

    IF p_task_mode NOT IN ('student', 'pro') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TASK_MODE', 'message', 'Mod yalnızca student veya pro olabilir.');
    END IF;

    IF p_priority NOT IN ('Düşük', 'Orta', 'Yüksek', 'Kritik') THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_PRIORITY', 'message', 'Geçersiz öncelik seviyesi.');
    END IF;

    IF p_task_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_TASK_TIME', 'message', 'Saat formatı HH:mm olmalıdır.');
    END IF;

    IF p_deadline IS NOT NULL THEN
        BEGIN
            v_task_start := (p_scheduled_date || ' ' || p_task_time || ':00')::timestamptz;
            v_task_end := v_task_start + (p_duration_minutes || ' minutes')::interval;
            IF v_task_end > p_deadline THEN
                RETURN jsonb_build_object('success', false, 'code', 'DEADLINE_EXCEEDED', 'message', 'Görev bitiş saati teslim tarihini geçemez.');
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('success', false, 'code', 'INVALID_DATE_FORMAT', 'message', 'Geçersiz tarih formatı.');
        END;
    END IF;

    INSERT INTO public.profiles (id, email)
    VALUES (v_user_id, auth.jwt()->>'email')
    ON CONFLICT (id) DO NOTHING;

    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF coalesce(v_profile.is_premium, false) = false AND coalesce(v_profile.voice_command_usage, 0) >= 3 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'QUOTA_EXCEEDED',
            'message', 'Haftalık 3 sesli komut kotanız doldu. Sınırsız kullanım için Elit Kulübe geçebilirsiniz.'
        );
    END IF;

    INSERT INTO public.weekly_tasks (
        user_id, title, category, day_index, scheduled_date, week_start_date,
        task_mode, task_time, duration_minutes, priority, deadline, reminder_time,
        is_completed, version, sync_status
    ) VALUES (
        v_user_id, v_clean_title, coalesce(p_category, 'Sesli Plan'), p_day_index,
        p_scheduled_date::date, p_week_start_date::date, p_task_mode, p_task_time,
        p_duration_minutes, p_priority, p_deadline, coalesce(p_reminder_time, '1 Saat Önce'),
        false, 1, 'pending'
    ) RETURNING * INTO v_new_task;

    INSERT INTO public.sync_operations (
        task_id, user_id, operation_type, idempotency_key, desired_state, state_version, status
    ) VALUES (
        v_new_task.id, v_user_id, 'create', coalesce(p_request_id, 'voice_' || v_new_task.id::text || '_1'),
        jsonb_build_object(
            'task_id', v_new_task.id, 'title', v_new_task.title, 'category', v_new_task.category,
            'task_mode', v_new_task.task_mode, 'scheduled_date', v_new_task.scheduled_date::text,
            'week_start_date', v_new_task.week_start_date::text, 'day_index', v_new_task.day_index,
            'task_time', v_new_task.task_time, 'duration_minutes', v_new_task.duration_minutes,
            'priority', v_new_task.priority, 'deadline', v_new_task.deadline,
            'reminder_time', v_new_task.reminder_time, 'is_completed', false, 'version', 1
        ),
        1, 'pending'
    ) ON CONFLICT (user_id, idempotency_key) DO NOTHING;

    IF coalesce(v_profile.is_premium, false) = false THEN
        UPDATE public.profiles
        SET voice_command_usage = coalesce(v_profile.voice_command_usage, 0) + 1,
            updated_at = now()
        WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task));
END;
$$;

CREATE OR REPLACE FUNCTION public.get_all_user_calendar_events()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_events jsonb;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'calendar_id', calendar_id,
        'calendar_event_id', calendar_event_id
    )), '[]'::jsonb)
    INTO v_events
    FROM public.weekly_tasks
    WHERE user_id = v_user_id 
      AND calendar_id IS NOT NULL 
      AND calendar_event_id IS NOT NULL;

    RETURN v_events;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_user_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum bulunamadı.');
    END IF;

    DELETE FROM public.sync_operations WHERE user_id = v_user_id;
    DELETE FROM public.weekly_tasks WHERE user_id = v_user_id;
    DELETE FROM public.profiles WHERE id = v_user_id;
    DELETE FROM auth.users WHERE id = v_user_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_my_profile_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.consume_ai_quota(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refund_ai_quota(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_my_subscription() TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_task_with_outbox(text, text, integer, text, text, text, integer, text, timestamptz, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, integer, timestamptz, text, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.claim_pending_delete_operations(integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_delete_side_effects(uuid, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_task_durable(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, text, integer, text, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_all_user_calendar_events() TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_user_account() TO authenticated;