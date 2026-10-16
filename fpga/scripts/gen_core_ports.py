#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Emit AXI port declarations / connections used in rtl/web888_core.v (dev helper)."""
import sys
M_OUT = [("awid","ID"),("awaddr",32),("awlen",4),("awsize",3),("awburst",2),("awlock",2),
         ("awcache",4),("awprot",3),("awqos",4),("awvalid",1),("wid","ID"),("wdata",64),
         ("wstrb",8),("wlast",1),("wvalid",1),("bready",1),("arid","ID"),("araddr",32),
         ("arlen",4),("arsize",3),("arburst",2),("arlock",2),("arcache",4),("arprot",3),
         ("arqos",4),("arvalid",1),("rready",1)]
M_IN = [("awready",1),("wready",1),("bid","ID"),("bresp",2),("bvalid",1),("arready",1),
        ("rid","ID"),("rdata",64),("rresp",2),("rlast",1),("rvalid",1)]
def w(n, idw): n = idw if n == "ID" else n; return "" if n == 1 else f"[{n-1}:0] "
mode = sys.argv[1]
for m in sys.argv[2:]:
    if mode == "decl":
        for s, n in M_OUT: print(f"  output wire {w(n,6)}m_axi_{m}_{s},")
        for s, n in M_IN:  print(f"  input  wire {w(n,6)}m_axi_{m}_{s},")
    else:
        for s, _ in M_OUT + M_IN: print(f"    .m_axi_{s}(m_axi_{m}_{s}),")
