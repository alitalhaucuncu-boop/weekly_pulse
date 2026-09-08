-- WeeklyPulse Canonical AI Quota & Refund RPCs
-- P0-03, P0-04, P0-05, P0-07 Düzeltmeleri

DROP FUNCTION IF EXISTS public.consume_ai_quota(text);
DROP FUNCTION IF EXISTS public.refund_ai_quota(text);

CREATE TABLE IF NOT EXISTS public.ai_quota_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    request_id text NOT NULL,
    status text NOT NULL DEFAULT 'consumed',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT unique_user_ai_request UNIQUE (user_id, request_id)
);

ALTER TABLE public.ai_quota_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own ai quota logs" ON public.ai_quota_logs;
CREATE POLICY "Users can read own ai quota logs"
ON public.ai_quota_logs FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Tek Canonical consume_ai_quota (P0-03 & P0-04)
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
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum açılmamış.');
    END IF;

    SELECT * INTO v_existing_log 
    FROM public.ai_quota_logs 
    WHERE user_id = v_user_id AND request_id = p_request_id;

    IF FOUND THEN
        SELECT is_premium, ai_usage INTO v_is_premium, v_ai_usage FROM public.profiles WHERE id = v_user_id;
        RETURN jsonb_build_object(
            'success', true,
            'ai_usage', v_ai_usage,
            'is_premium', v_is_premium,
            'idempotent_replay', true
        );
    END IF;

    SELECT is_premium, ai_usage INTO v_is_premium, v_ai_usage
    FROM public.profiles
    WHERE id = v_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Profil bulunamadı.');
    END IF;

    IF NOT v_is_premium AND v_ai_usage >= 1 THEN
        RETURN jsonb_build_object('success', false, 'message', 'Haftalık Akıllı Analiz kotanız doldu.');
    END IF;

    IF NOT v_is_premium THEN
        UPDATE public.profiles
        SET ai_usage = ai_usage + 1
        WHERE id = v_user_id;
    END IF;

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
    ) ON CONFLICT (user_id, request_id) DO NOTHING;

    RETURN jsonb_build_object(
        'success', true,
        'ai_usage', CASE WHEN v_is_premium THEN 0 ELSE v_ai_usage + 1 END,
        'is_premium', v_is_premium
    );
END;
$$;

-- Guarded ve Idempotent refund_ai_quota (P0-05)
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
        RETURN jsonb_build_object('success', false, 'message', 'Oturum açılmamış.');
    END IF;

    SELECT * INTO v_log
    FROM public.ai_quota_logs
    WHERE user_id = v_user_id AND request_id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'İade edilecek tüketim kaydı bulunamadı.');
    END IF;

    IF v_log.status = 'refunded' THEN
        SELECT ai_usage INTO v_usage FROM public.profiles WHERE id = v_user_id;
        RETURN jsonb_build_object('success', true, 'ai_usage', v_usage, 'message', 'Zaten iade edilmiş.');
    END IF;

    SELECT is_premium INTO v_is_premium FROM public.profiles WHERE id = v_user_id FOR UPDATE;

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