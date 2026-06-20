-- Privacy-safe location display: stores city/region name, never shown as raw GPS.
-- lat and lng are retained for internal distance calculations in the Local channel only.

alter table clips
  add column if not exists location_display text;
