-- WeeklyPulse Canonical Production Migration v12 (P0 Hotfix & Ledger Parity)

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

-- 2. SYNC_OPERATIONS & ARŞİV TABLOSU
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
TO authenticated
USING (auth.uid() = user_id);

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

-- FK ON DELETE SET NULL
ALTER TABLE public.sync_operations DROP CONSTRAINT IF EXISTS sync_operations_task_id_fkey;
ALTER TABLE public.sync_operations 
ADD CONSTRAINT sync_operations_task_id_fkey 
FOREIGN KEY (task_id) REFERENCES public.weekly_tasks(id) ON DELETE SET NULL;

-- Deterministik backfill
UPDATE public.sync_operations 
SET idempotency_key = 'legacy_op_' || id::text 
WHERE idempotency_key IS NULL OR trim(idempotency_key) = '';

ALTER TABLE public.sync_operations ALTER COLUMN idempotency_key SET NOT NULL;

-- Mükerrer kayıtları arşivleyip temizle
WITH ranked_ops AS (
    SELECT id, user_id, task_id, operation_type, idempotency_key, desired_state, status, attempt_count,
           ROW_NUMBER() OVER (
               PARTITION BY user_id, idempotency_key 
               ORDER BY 
                   CASE status 
                       WHEN 'completed' THEN 1 
                       WHEN 'processing' THEN 2 
                       WHEN 'pending' THEN 3 
                       ELSE 4 
                   END,
                   created_at ASC
           ) as rn
    FROM public.sync_operations
),
duplicates_to_archive AS (
    SELECT * FROM ranked_ops WHERE rn > 1
)
INSERT INTO public.sync_operations_archive (
    original_operation_id, user_id, task_id, operation_type, idempotency_key, desired_state, status, attempts, archive_reason
)
SELECT id, user_id, task_id, operation_type, idempotency_key, desired_state, status, attempt_count, 'duplicate_dedup_cleanup'
FROM duplicates_to_archive;

WITH ranked_ops AS (
    SELECT id,
           ROW_NUMBER() OVER (
               PARTITION BY user_id, idempotency_key 
               ORDER BY 
                   CASE status 
                       WHEN 'completed' THEN 1 
                       WHEN 'processing' THEN 2 
                       WHEN 'pending' THEN 3 
                       ELSE 4 
                   END,
                   created_at ASC
           ) as rn
    FROM public.sync_operations
)
DELETE FROM public.sync_operations 
WHERE id IN (SELECT id FROM ranked_ops WHERE rn > 1);

-- Yalnızca idempotency_key içeren unique constraint'leri kaldır
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
DROP POLICY IF EXISTS "Users can manage their own sync operations" ON public.sync_operations;
DROP POLICY IF EXISTS "sync_operations_user_policy" ON public.sync_operations;

CREATE POLICY "Users can only read their sync operations"
ON public.sync_operations FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 3. UNIFIED QUOTA LEDGER
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

CREATE INDEX IF NOT EXISTS idx_quota_ledger_lookup 
ON public.user_quota_ledger (user_id, quota_type, period_key, status);

ALTER TABLE public.user_quota_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can read own quota ledger" ON public.user_quota_ledger;
CREATE POLICY "Users can read own quota ledger"
ON public.user_quota_ledger FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 4. CANONICAL RPC FONKSİYONLARI

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

-- create_voice_task_with_quota (P0 Voice Ledger Result Check Düzeltmesi)
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

    -- 1. Profil satırını kilitle
    SELECT is_premium, last_usage_week 
    INTO v_is_premium, v_last_usage_week
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Kullanıcı profili bulunamadı.');
    END IF;

    -- 2. Kilit sonrası idempotensi kontrolü
    SELECT * INTO v_existing_task 
    FROM public.sync_operations 
    WHERE user_id = v_user_id AND idempotency_key = p_request_id;

    IF FOUND AND v_existing_task.task_id IS NOT NULL THEN
        SELECT * INTO v_new_task FROM public.weekly_tasks WHERE id = v_existing_task.task_id;
        RETURN jsonb_build_object('success', true, 'task', to_jsonb(v_new_task), 'idempotent_replay', true);
    END IF;

    -- 3. Rollover ve Ledger üzerinden kota kontrolü
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

    -- Unified Ledger kaydı ve P0: RETURNING id ile doğrulanmış kayıt
    INSERT INTO public.user_quota_ledger (
        user_id, quota_type, period_key, request_id, status, created_at
    ) VALUES (
        v_user_id, 'voice', v_current_period, p_request_id, 'consumed', now()
    ) ON CONFLICT (user_id, quota_type, request_id) DO NOTHING
    RETURNING id INTO v_ledger_id;

    -- Profil sayacı yalnızca ledger kaydı gerçekten yazıldıysa güncellenir
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

-- consume_ai_quota (P0: v_user_id Düzeltmesi)
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

    -- Kilit sonrası istek tekrarı kontrolü
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

    -- Unified Ledger ile period kotası kontrolü
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

    -- P0 DÜZELTMESİ: İlk değer p_request_id yerine kesin olarak v_user_id
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

-- refund_ai_quota
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

-- 5. EXPLICIT ROLE-BASED ALLOWLIST
REVOKE ALL ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_task_mutation(uuid, text, text, integer, text, text, text, integer, text, timestamptz, text, boolean, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_voice_task_with_quota(text, text, text, integer, text, text, text, integer, text, timestamptz, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.consume_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_ai_quota(text) TO authenticated;

REVOKE ALL ON FUNCTION public.refund_ai_quota(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refund_ai_quota(text) TO authenticated;