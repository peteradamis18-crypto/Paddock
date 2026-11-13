// ZOrder (W0-3 review #1): is an overlay window below the sim's window? Windows keeps windows in one z-order list; walking up from
// the overlay (GetWindow GW_HWNDPREV, the window just above) either meets the sim (the sim covers it) or reaches the top.
// The TOPMOST flag alone is not enough: while he drives the sim is TOPMOST too, so after a focus steal and return the sim can sit
// above overlays that still carry the flag. Pure: the walk is passed in, so tests\jobs-test.ps1 checks it with a pretend z-order.
using System;

namespace IRDash
{
    static class ZOrder
    {
        // above(h) = the window just above h (IntPtr.Zero at the top). max: a guard against a list that changes while it is walked.
        public static bool SimAbove(IntPtr overlay, IntPtr sim, Func<IntPtr, IntPtr> above, int max)
        {
            if (overlay == IntPtr.Zero || sim == IntPtr.Zero || overlay == sim) return false;
            IntPtr h = overlay;
            for (int i = 0; i < max; i++)
            {
                h = above(h);
                if (h == IntPtr.Zero) return false;
                if (h == sim) return true;
            }
            return false;
        }

        // raise the overlays when one is below the sim, when one lost its TOPMOST flag, or when the sim has just come back to the front
        public static bool ShouldRaise(bool driving, bool wasDriving, bool anyBelow, bool simFrontNow, bool simFrontBefore)
        {
            if (!driving) return false;
            return !wasDriving || anyBelow || (simFrontNow && !simFrontBefore);
        }
    }
}
