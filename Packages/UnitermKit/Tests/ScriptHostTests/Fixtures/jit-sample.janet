# Maps machine code that returns 42, then calls it and prints the result. It needs ffi-jit and
# ffi-use. Under the hardened runtime, the kernel ends the process when the code runs unless the
# command holds the entitlement for unsigned executable memory.
(def code
  (case (os/arch)
    :aarch64 (buffer/from-bytes 0x40 0x05 0x80 0x52 0xc0 0x03 0x5f 0xd6)
    :x64 (buffer/from-bytes 0xb8 0x2a 0x00 0x00 0x00 0xc3)
    (error (string "no sample for " (os/arch)))))

(print (ffi/call (ffi/jitfn code) (ffi/signature :default :int)))
