-- Migration: Email log welcome idempotency + broadcast reclassification
-- Date: 2026-04-20
-- Context: 2026-04-14 broadcast of ~151 emails about Telegram/notifications feature
-- was logged as email_type='welcome' because admins used the welcome channel
-- for a manual campaign. This polluted the "welcome sent" signup metric.
-- Also found 3 users who had received auto-welcome twice (no idempotency).
-- Project: brasilhorizonte (dawvgbopyemcayavcatd)

BEGIN;

-- Step 1: Reclassify broadcasts (sent_by NOT NULL was always admin-triggered, not signup auto-welcome)
UPDATE public.email_log
SET email_type = 'broadcast_feature_announcement',
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'reclassified_at', now()::text,
      'original_type', 'welcome',
      'campaign', 'telegram_notifications_2026_04'
    )
WHERE email_type = 'welcome'
  AND sent_by IS NOT NULL
  AND (content_title ILIKE '%notifica%' OR subject ILIKE '%carteira agora fala%');

UPDATE public.email_log
SET email_type = 'broadcast',
    metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'reclassified_at', now()::text,
      'original_type', 'welcome'
    )
WHERE email_type = 'welcome' AND sent_by IS NOT NULL;

-- Step 2: Dedupe duplicate auto-welcomes — keep earliest per recipient
WITH dups AS (
  SELECT id, row_number() OVER (PARTITION BY recipient_user_id ORDER BY created_at ASC) AS rn
  FROM public.email_log
  WHERE email_type = 'welcome' AND sent_by IS NULL
)
DELETE FROM public.email_log WHERE id IN (SELECT id FROM dups WHERE rn > 1);

-- Step 3: Unique partial index — one auto-welcome per user forever
CREATE UNIQUE INDEX IF NOT EXISTS email_log_unique_auto_welcome
ON public.email_log (recipient_user_id)
WHERE email_type = 'welcome' AND sent_by IS NULL;

-- Step 4: Shape constraint — welcome must be auto (sent_by NULL + metadata.auto=true)
ALTER TABLE public.email_log DROP CONSTRAINT IF EXISTS email_log_welcome_shape;
ALTER TABLE public.email_log
ADD CONSTRAINT email_log_welcome_shape
CHECK (
  email_type != 'welcome'
  OR (sent_by IS NULL AND (metadata->>'auto')::boolean IS TRUE)
);

-- Step 5: Idempotent helper RPC — callers use this instead of direct INSERT
CREATE OR REPLACE FUNCTION public.log_welcome_email(
  p_user_id uuid,
  p_email text,
  p_name text DEFAULT NULL,
  p_subject text DEFAULT 'Sua conta está ativa',
  p_template_key text DEFAULT 'welcome_default'
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.email_log (
    recipient_user_id, recipient_email, recipient_name,
    email_type, subject, content_type, status, metadata, sent_by
  ) VALUES (
    p_user_id, p_email, p_name,
    'welcome', p_subject, 'welcome', 'sent',
    jsonb_build_object('auto', true, 'template_key', p_template_key),
    NULL
  )
  ON CONFLICT (recipient_user_id)
    WHERE email_type = 'welcome' AND sent_by IS NULL
    DO NOTHING;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_welcome_email(uuid, text, text, text, text) TO service_role;

COMMIT;
