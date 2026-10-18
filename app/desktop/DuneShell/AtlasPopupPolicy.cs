using System;

namespace DuneShell
{
    public static class AtlasPopupPolicy
    {
        public static bool IsAtlasPopup(Uri portal, Uri requested)
        {
            if (portal == null || requested == null || !portal.IsAbsoluteUri || !requested.IsAbsoluteUri ||
                !portal.IsLoopback || !requested.IsLoopback || requested.UserInfo.Length != 0 ||
                !string.Equals(portal.GetLeftPart(UriPartial.Authority), requested.GetLeftPart(UriPartial.Authority), StringComparison.OrdinalIgnoreCase) ||
                requested.AbsolutePath != "/api/v1/maps/atlas/view") return false;
            foreach (var part in requested.Query.TrimStart('?').Split('&'))
                if (part == "view=map") return true;
            return false;
        }
    }
}
