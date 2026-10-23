"""Short leases belong to viewers, never to scheduled server work."""
import time

class Leases:
    def __init__(self,clock=time.monotonic,seconds=30):
        self.clock=clock;self.seconds=seconds;self.viewers={}
    def touch(self,viewer):
        self.viewers[viewer]=self.clock()+self.seconds
    def release(self,viewer):
        self.viewers.pop(viewer,None)
    def active(self):
        now=self.clock()
        self.viewers={key:until for key,until in self.viewers.items() if until>now}
        return bool(self.viewers)
