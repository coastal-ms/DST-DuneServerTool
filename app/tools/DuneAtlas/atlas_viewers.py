"""Short leases belong to viewers, never to scheduled server work."""
import time

class Leases:
    def __init__(self,clock=time.monotonic,seconds=30):
        self.clock=clock;self.seconds=seconds;self.viewers={};self.preferences={}
    def touch(self,viewer,preferences=None):
        self.viewers[viewer]=self.clock()+self.seconds
        if preferences is not None:self.preferences[viewer]=preferences
    def release(self,viewer):
        self.viewers.pop(viewer,None)
        self.preferences.pop(viewer,None)
    def active(self):
        now=self.clock()
        self.viewers={key:until for key,until in self.viewers.items() if until>now}
        self.preferences={key:value for key,value in self.preferences.items() if key in self.viewers}
        return bool(self.viewers)
    def selections(self):
        self.active()
        return list(self.preferences.values())
