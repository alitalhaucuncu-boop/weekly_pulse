-- WeeklyPulse Canonical Production Migration v15
-- Kapsam: complete_delete_operation Yetki & State Machine, Karantina Tablosu ve Idempotent Delete

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

-- 2. KARANTİNA VE ARŞİV TABLOSU GÜVENCESİ (P0: Rastgele UUID Backfill Kaldırıldı)
CREATE TABLE IF NOT EXISTS public.sync_operations_quarantine (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    archive_id uuid,
    raw_payload jsonb,
    quarantine_reason text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.sync_operations_archive (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    original_operation_id uuid,
    user_id uuid,
    task_id uuid,
    operation_type text,
    idempotency_key text,
    desired_state jsonb,
    status text,
    attempts integer,
    archived_at timestamptz NOT NULL DEFAULT now(),
    archive_reason text NOT NULL DEFAULT 'duplicate_resolution'
);

ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS original_operation_id uuid;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS user_id uuid;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS task_id uuid;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS operation_type text;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS idempotency_key text;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS desired_state jsonb;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS status text;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS attempts integer;
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS archived_at timestamptz DEFAULT now();
ALTER TABLE public.sync_operations_archive ADD COLUMN IF NOT EXISTS archive_reason text DEFAULT 'duplicate_resolution';

-- Rastgele UUID üretmek yerine sahipsiz kayıtları karantinaya al
INSERT INTO public.sync_operations_quarantine (archive_id, raw_payload, quarantine_reason)
SELECT id, to_jsonb(a), 'missing_owner_or_operation_provenance'
FROM public.sync_operations_archive a
WHERE a.user_id IS NULL OR a.original_operation_id IS NULL;

DELETE FROM public.sync_operations_archive
WHERE user_id IS NULL OR original_operation_id IS NULL;

-- Temizlenen arşiv tablosunda NOT NULL constraint garantisi
ALTER TABLE public.sync_operations_archive ALTER COLUMN original_operation_id SET NOT NULL;
ALTER TABLE public.sync_operations_archive ALTER COLUMN user_id SET NOT NULL;
ALTER TABLE public.sync_operations_archive ALTER COLUMN operation_type SET NOT NULL;

ALTER TABLE public.sync_operations_archive ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can only read own archived operations" ON public.sync_operations_archive;
CREATE POLICY "Users can only read own archived operations"
ON public.sync_operations_archive FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3. SYNC_OPERATIONS ANA TABLO VE UNIQUE KISITLAMALARI
CREATE TABLE IF NOT EXISTS public.sync_operations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    task_id uuid REFERENCES public.weekly_tasks(id) ON DELETE SET NULL,
    operation_type text NOT NULL,
    idempotency_key text,
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
ALTER TABLE public.sync_operations ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();

ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS sync_operations_task_id_fkey;
ALTER TABLE public.sync_operations 
ADD CONSTRAINT sync_operations_task_id_fkey 
FOREIGN KEY (task_id) REFERENCES public.weekly_tasks(id) ON DELETE SET NULL;

UPDATE public.sync_operations 
SET idempotency_key = 'legacy_op_' || id::text 
WHERE idempotency_key IS NULL OR trim(idempotency_key) = '';

ALTER TABLE public.sync_operations ALTER COLUMN idempotency_key SET NOT NULL;

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (
        SELECT c.conname
        FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
        WHERE c.conrelid = 'public.sync_operations'::regclass
          AND c.contype = 'u'
          AND a.attname = 'idempotency_key'
    ) LOOP
        EXECUTE 'ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS ' || quote_ident(r.conname);
    END LOOP;
END $$;

ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS unique_user_outbox_key;
ALTER TABLE public.sync_operations 
ADD CONSTRAINT unique_user_outbox_key UNIQUE (user_id, idempotency_key);

ALTER TABLE public.sync_operations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can only read their sync operations" ON public.sync_operations;
CREATE POLICY "Users can only read their sync operations"
ON public.sync_operations FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 4. USER_QUOTA_LEDGER KESİN NOT NULL & CONSTRAINT PARITY
CREATE TABLE IF NOT EXISTS public.user_quota_ledger (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    quota_type text NOT NULL CHECK (quota_type IN ('ai', 'voice')),
    period_key text NOT NULL DEFAULT to_char(now(), 'IYYY-IW'),
    request_id text NOT NULL,
    status text NOT NULL DEFAULT 'consumed' CHECK (status IN ('consumed', 'refunded')),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_user_quota_request UNIQUE (user_id, quota_type, request_id)
);

ALTER TABLE public.user_quota_ledger ADD COLUMN IF NOT EXISTS quota_type text DEFAULT 'ai';
ALTER TABLE public.user_quota_ledger ADD COLUMN IF NOT EXISTS period_key text DEFAULT to_char(now(), 'IYYY-IW');
ALTER TABLE public.user_quota_ledger ADD COLUMN IF NOT EXISTS request_id text;
ALTER TABLE public.user_quota_ledger ADD COLUMN IF NOT EXISTS status text DEFAULT 'consumed';
ALTER TABLE public.user_quota_ledger ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();

UPDATE public.user_quota_ledger SET quota_type = 'ai' WHERE quota_type IS NULL;
UPDATE public.user_quota_ledger SET period_key = to_char(now(), 'IYYY-IW') WHERE period_key IS NULL;
UPDATE public.user_quota_ledger SET request_id = 'legacy_req_' || id::text WHERE request_id IS NULL;
UPDATE public.user_quota_ledger SET status = 'consumed' WHERE status IS NULL;

ALTER TABLE public.user_quota_ledger ALTER COLUMN quota_type SET NOT NULL;
ALTER TABLE public.user_quota_ledger ALTER COLUMN period_key SET NOT NULL;
ALTER TABLE public.user_quota_ledger ALTER COLUMN request_id SET NOT NULL;
ALTER TABLE public.user_quota_ledger ALTER COLUMN status SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'check_user_quota_ledger_type') THEN
        ALTER TABLE public.user_quota_ledger ADD CONSTRAINT check_user_quota_ledger_type CHECK (quota_type IN ('ai', 'voice'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'check_user_quota_ledger_status') THEN
        ALTER TABLE public.user_quota_ledger ADD CONSTRAINT check_user_quota_ledger_status CHECK (status IN ('consumed', 'refunded'));
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_quota_ledger_lookup 
ON public.user_quota_ledger (user_id, quota_type, period_key, status);

ALTER TABLE public.user_quota_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read own quota ledger" ON public.user_quota_ledger;
CREATE POLICY "Users can read own quota ledger"
ON public.user_quota_ledger FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 5. CANONICAL complete_delete_operation RPC (P0: Sıkı Operation Type & State Transition Koruması)
CREATE OR REPLACE FUNCTION public.complete_delete_operation(
    p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id uuid;
    v_op record;
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
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'İşlem bulunamadı.');
    END IF;

    -- P0: Yalnızca delete türündeki operasyonlara izin ver
    IF v_op.operation_type <> 'delete' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_OPERATION_TYPE',
            'message', 'Bu fonksiyon yalnızca silme operasyonlarını tamamlamak içindir.'
        );
    END IF;

    -- P0: State machine kontrolü
    IF v_op.status = 'completed' THEN
        RETURN jsonb_build_object('success', true, 'message', 'İşlem zaten tamamlanmış.', 'idempotent_replay', true);
    END IF;

    IF v_op.status NOT IN ('pending', 'processing', 'partial') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_STATE_TRANSITION',
            'message', 'Bu durumdaki operasyon tamamlanamaz.'
        );
    END IF;

    UPDATE public.sync_operations
    SET status = 'completed', updated_at = now()
    WHERE id = p_operation_id AND user_id = v_user_id;

    RETURN jsonb_build_object('success', true, 'message', 'Silme işlemi başarıyla tamamlandı.');
END;
$$;

-- 6. CANONICAL delete_task_durable RPC (P1: Concurrency-Safe Lock Sonrası Idempotency)
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

    -- 1. Görevi kilitle
    SELECT * INTO v_task
    FROM public.weekly_tasks
    WHERE id = p_task_id AND user_id = v_user_id
    FOR UPDATE;

    -- 2. Görev bulunamadıysa (aynı anda başka istek silmiş olabilir), kilit sonrası outbox'ı kontrol et
    IF NOT FOUND THEN
        SELECT * INTO v_existing_op
        FROM public.sync_operations
        WHERE user_id = v_user_id AND idempotency_key = 'delete_' || p_task_id::text;

        IF FOUND THEN
            RETURN jsonb_build_object('success', true, 'message', 'Görev silinmiş ve temizleme kuyruğunda.', 'idempotent_replay', true);
        END IF;

        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Görev bulunamadı.');
    END IF;

    -- 3. Dış temizlik kaydı oluştur
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
            'calendar_event_id', v_task.calendar_event_id
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

-- 7. DİĞER CANONICAL RPC'LER
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
    v_effective_mode text;
    v_current_period text;
    v_last_usage_week text;
    v_consumed_voice integer;
    v_existing_task record;
    v_outbox_id uuid;
    v_ledger_id uuid;
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

    v_current_period := to_char(now(), 'IYYY-IW');

    SELECT is_premium, last_usage_week 
    INTO v_is_premium, v_last_usage_week
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kullanıcı profili bulunamadı.');
    END IF;

    SELECT * INTO v_existing_task 
    FROM public.sync_operations 
    WHERE user_id = v_user_id AND idempotency_key = p_request_id;

    IF FOUND AND v_existing_task.task_id IS NOT NULL THEN
        SELECT * INTO v_new_task FROM public.weekly_tasks WHERE id = v_existing_task.task_id;
        RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task), 'idempotent_replay', true);
    END IF;

    IF NOT v_is_premium THEN
        SELECT count(*) INTO v_consumed_voice 
        FROM public.user_quota_ledger 
        WHERE user_id = v_user_id 
          AND quota_type = 'voice' 
          AND period_key = v_current_period 
          AND status = 'consumed';

        IF v_consumed_voice >= 3 THEN
            RETURN jsonb_build_object('success', false, 'code', 'LIMIT_EXCEEDED', 'message', 'Haftalık sesli komut kotanız doldu.');
        END IF;
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
            'category', p_category,
            'task_mode', v_effective_mode,
            'scheduled_date', p_scheduled_date,
            'week_start_date', p_week_start_date,
            'day_index', p_day_index,
            'task_time', p_task_time,
            'duration_minutes', p_duration_minutes,
            'priority', p_priority,
            'deadline', p_deadline,
            'reminder_time', p_reminder_time,
            'is_completed', false,
            'version', 1
        ),
        1,
        'pending'
    ) RETURNING id INTO v_outbox_id;

    IF v_outbox_id IS NULL THEN
        RAISE EXCEPTION 'Sesli görev outbox kaydı oluşturulamadı.';
    END IF;

    INSERT INTO public.user_quota_ledger (
        user_id, quota_type, period_key, request_id, status, created_at
    ) VALUES (
        v_user_id, 'voice', v_current_period, p_request_id, 'consumed', now()
    ) ON CONFLICT (user_id, quota_type, request_id) DO NOTHING
    RETURNING id INTO v_ledger_id;

    IF NOT v_is_premium AND v_ledger_id IS NOT NULL THEN
        UPDATE public.profiles
        SET voice_usage = voice_usage + 1, last_usage_week = v_current_period
        WHERE id = v_user_id;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'task', to_jsonb(v_new_task)
    );
END;
$$;

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
    v_current_period text;
    v_last_usage_week text;
    v_consumed_count integer;
    v_ledger_id uuid;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'UNAUTHORIZED', 'message', 'Oturum açılmamış.');
    END IF;

    IF trim(p_request_id) = '' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_REQUEST_ID', 'message', 'Geçersiz istek kimliği.');
    END IF;

    v_current_period := to_char(now(), 'IYYY-IW');

    SELECT is_premium, ai_usage, last_usage_week 
    INTO v_is_premium, v_ai_usage, v_last_usage_week
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Profil bulunamadı.');
    END IF;

    SELECT * INTO v_existing_log 
    FROM public.user_quota_ledger 
    WHERE user_id = v_user_id AND quota_type = 'ai' AND request_id = p_request_id;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'success', true,
            'ai_usage', v_ai_usage,
            'is_premium', v_is_premium,
            'idempotent_replay', true
        );
    END IF;

    IF v_last_usage_week IS DISTINCT FROM v_current_period THEN
        v_ai_usage := 0;
        UPDATE public.profiles 
        SET ai_usage = 0, voice_usage = 0, last_usage_week = v_current_period 
        WHERE id = v_user_id;
    END IF;

    IF NOT v_is_premium THEN
        SELECT count(*) INTO v_consumed_count 
        FROM public.user_quota_ledger 
        WHERE user_id = v_user_id 
          AND quota_type = 'ai'
          AND period_key = v_current_period 
          AND status = 'consumed';

        IF v_consumed_count >= 1 THEN
            RETURN jsonb_build_object('success', false, 'code', 'LIMIT_EXCEEDED', 'message', 'Haftalık Akıllı Analiz kotanız doldu.');
        END IF;
    END IF;

    INSERT INTO public.user_quota_ledger (
        user_id, quota_type, period_key, request_id, status, created_at
    ) VALUES (
        v_user_id, 'ai', v_current_period, p_request_id, 'consumed', now()
    ) RETURNING id INTO v_ledger_id;

    IF NOT v_is_premium AND v_ledger_id IS NOT NULL THEN
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

    SELECT is_premium, ai_usage INTO v_is_premium, v_usage 
    FROM public.profiles 
    WHERE id = v_user_id 
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kullanıcı profili bulunamadı.');
    END IF;

    SELECT * INTO v_log
    FROM public.user_quota_ledger
    WHERE user_id = v_user_id AND quota_type = 'ai' AND request_id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'İade edilecek tüketim kaydı bulunamadı.');
    END IF;

    IF v_log.status = 'refunded' THEN
        RETURN jsonb_build_object('success', true, 'ai_usage', v_usage, 'message', 'Bu istek zaten iade edilmiş.');
    ELSIF v_log.status <> 'consumed' THEN
        RETURN jsonb_build_object('success', false, 'code', 'INVALID_STATUS', 'message', 'Yalnızca aktif tüketimler iade edilebilir.');
    END IF;

    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET ai_usage = GREATEST(0, ai_usage - 1)
        WHERE id = v_user_id
        RETURNING ai_usage INTO v_usage;
    ELSE
        v_usage := 0;
    END IF;

    UPDATE public.user_quota_ledger
    SET status = 'refunded'
    WHERE user_id = v_user_id AND quota_type = 'ai' AND request_id = p_request_id;

    RETURN jsonb_build_object(
        'success', true,
        'ai_usage', v_usage,
        'message', 'Kota başarıyla iade edildi.'
    );
END;
$$;

-- 8. ROLE-BASED ALLOWLIST (P0 Yetkilendirme)
REVOKE ALL ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.consume_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_ai_quota(text) TO authenticated;

REVOKE ALL ON FUNCTION public.refund_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_ai_quota(text) TO authenticated;

REVOKE ALL ON FUNCTION public.delete_task_durable(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_task_durable(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.complete_delete_operation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_delete_operation(uuid) TO authenticated;