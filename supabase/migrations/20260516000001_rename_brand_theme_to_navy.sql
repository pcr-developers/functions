-- 20260516000001_rename_brand_theme_to_navy.sql
--
-- The "brand" theme was rebranded to "navy" (palette shifted from cyan to
-- a clean royal-blue navy). Existing users have their picked theme persisted
-- in `user_preferences.theme` as the literal string 'brand'. The web app's
-- `applyTheme()` / `readTheme()` / cookie-default path now only understand
-- 'navy' / 'dark' / 'system' / 'peach' / 'forest' / 'light', so 'brand'
-- rows would fall through to the warm-light fallback for those users on
-- next login.
--
-- Idempotent: the WHERE clause restricts to rows that still carry the
-- legacy value, so re-running is a no-op.

UPDATE user_preferences
SET theme = 'navy',
    updated_at = now()
WHERE theme = 'brand';
