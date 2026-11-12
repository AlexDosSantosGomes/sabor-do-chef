-- Adds a separate enum value for pickup orders. Existing orders are untouched.
ALTER TYPE public.order_type ADD VALUE IF NOT EXISTS 'PICKUP';
