-- Portal-only session checks. No session tokens or personal data are exposed.
CREATE OR REPLACE FUNCTION portal_private.active_session()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS (
   SELECT 1 FROM auth.sessions s
   WHERE s.id::text = (auth.jwt()->>'session_id')
     AND s.user_id = auth.uid()
     AND s.created_at > now() - interval '8 hours'
     AND (s.not_after IS NULL OR s.not_after > now())
 )
$$;
REVOKE ALL ON FUNCTION portal_private.active_session() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION portal_private.active_session() TO authenticated;
CREATE OR REPLACE FUNCTION portal_private.allowed(c uuid, editing boolean DEFAULT false, publishing boolean DEFAULT false)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
 SELECT portal_private.active_session() AND EXISTS (
 SELECT 1 FROM public.portal_memberships m JOIN public.clients c1 ON c1.id=m.client_id
 WHERE m.client_id=c AND m.user_id=auth.uid() AND c1.deleted_at IS NULL
 AND (NOT editing OR m.role IN ('owner','editor'))
 AND (NOT publishing OR m.role='owner'))
$$;
ALTER POLICY self_membership ON public.portal_memberships
 USING (user_id=(SELECT auth.uid()) AND (SELECT portal_private.active_session()));
