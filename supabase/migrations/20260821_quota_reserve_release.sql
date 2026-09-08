-- AI Kota Tüketim & İade Yönetimi (P0-07)

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
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum açılmamış.');
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
    ) ON CONFLICT (request_id) DO NOTHING;

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
    v_usage integer;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Oturum açılmamış.');
    END IF;

    UPDATE public.profiles
    SET ai_usage = GREATEST(0, ai_usage - 1)
    WHERE id = v_user_id
    RETURNING ai_usage INTO v_usage;

    UPDATE public.ai_quota_logs
    SET status = 'refunded'
    WHERE request_id = p_request_id AND user_id = v_user_id;

    RETURN jsonb_build_object(
        'success', true,
        'ai_usage', v_usage,
        'message', 'Kota iade edildi.'
    );
END;
$$;