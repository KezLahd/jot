import json, sys, time
t0=time.time()
from faster_whisper import WhisperModel
m = WhisperModel("small", device="cpu", compute_type="int8")
t1=time.time()
segs, info = m.transcribe(sys.argv[1], vad_filter=True, beam_size=5)
segs=[[round(s.start,1),round(s.end,1),s.text.strip()] for s in segs]
t2=time.time()
print(json.dumps({"load_s":round(t1-t0,2),"transcribe_s":round(t2-t1,2),"segments":segs}))
