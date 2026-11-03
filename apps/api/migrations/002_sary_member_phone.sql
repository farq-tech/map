-- Optional phone number, so outing members can call or WhatsApp each other.
-- Additive and nullable: existing people keep working without one. Shown
-- only to members of the same outing (never on invite previews).
ALTER TABLE sary.users ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE sary.users DROP CONSTRAINT IF EXISTS users_phone_format;
ALTER TABLE sary.users ADD CONSTRAINT users_phone_format CHECK (phone IS NULL OR phone ~ '^\+[0-9]{8,15}$');
