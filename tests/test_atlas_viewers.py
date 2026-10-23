import sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'app/tools/DuneAtlas'))
from atlas_viewers import Leases

class ViewerLeases(unittest.TestCase):
    def test_one_paused_viewer_does_not_stop_a_peer(self):
        leases=Leases(clock=lambda:0)
        leases.touch('tablet');leases.touch('desktop')
        leases.release('tablet')
        self.assertTrue(leases.active())
        leases.release('desktop')
        self.assertFalse(leases.active())
    def test_abandoned_or_disconnected_viewer_expires_without_stop(self):
        now=[0];leases=Leases(clock=lambda:now[0])
        leases.touch('tablet');now[0]=29
        self.assertTrue(leases.active())
        now[0]=30
        self.assertFalse(leases.active())
    def test_peer_renewal_and_resuming_after_idle(self):
        now=[0];leases=Leases(clock=lambda:now[0])
        leases.touch('first');now[0]=20;leases.touch('second');now[0]=31
        self.assertTrue(leases.active());self.assertNotIn('first',leases.viewers)
        leases.release('second');self.assertFalse(leases.active())
        leases.touch('first');self.assertTrue(leases.active())

if __name__=='__main__': unittest.main()
