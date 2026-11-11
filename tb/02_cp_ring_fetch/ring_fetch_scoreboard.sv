`uvm_analysis_imp_decl(_wptr)
`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_dw)

// Checks:
//  1. data: the decoder receives exactly the dwords the CPU published, in ring order, none lost, none repeated
//  2. RPTR: the reported read pointer always equals the number of dwords delivered (mod ring size)
//  3. requests: every line request is aligned, inside the ring, and contains at least one dword of real work
class ring_fetch_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(ring_fetch_scoreboard)
  uvm_analysis_imp_wptr #(ring_wptr_item, ring_fetch_scoreboard) wptr_imp;
  uvm_analysis_imp_req  #(ring_req_item,  ring_fetch_scoreboard) req_imp;
  uvm_analysis_imp_dw   #(ring_dw_item,   ring_fetch_scoreboard) dw_imp;
  ring_fetch_config cfg;
  bit [31:0] exp_q[$];
  bit [RING_LOG2-1:0] exp_rptr;
  int n_dw, n_req, n_err;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    wptr_imp = new("wptr_imp", this);
    req_imp  = new("req_imp", this);
    dw_imp   = new("dw_imp", this);
    void'(uvm_config_db#(ring_fetch_config)::get(this, "", "cfg", cfg));
  endfunction

  function void err(string s);
    n_err++;
    `uvm_error("SB", s)
  endfunction

  function void write_wptr(ring_wptr_item w);
    foreach (w.data[i]) exp_q.push_back(w.data[i]);
  endfunction

  function void write_dw(ring_dw_item d);
    bit [31:0] e;
    n_dw++;
    if (d.rptr_before != exp_rptr)
      err($sformatf("RPTR is %0d but %0d dwords were delivered (mod %0d)", d.rptr_before, exp_rptr, RING_SIZE));
    exp_rptr++;
    if (exp_q.size() == 0) begin
      err($sformatf("dword %08h delivered but the CPU never published it", d.data));
      return;
    end
    e = exp_q.pop_front();
    if (e != d.data) err($sformatf("dword #%0d: expected %08h, got %08h", n_dw, e, d.data));
  endfunction

  function void write_req(ring_req_item r);
    int line, first, useful;
    n_req++;
    if (r.addr[4:0] != 0) err($sformatf("request address %08h is not 32-byte aligned", r.addr));
    if (r.addr < cfg.ring_base || r.addr >= cfg.ring_base + 4 * RING_SIZE)
      err($sformatf("request address %08h is outside the ring", r.addr));
    // useful = the line holds some dword in [rptr, wptr) at issue time (pending work, possibly already in FIFO)
    line = (r.addr - cfg.ring_base) / 32;
    useful = 0;
    for (bit [RING_LOG2-1:0] p = r.rptr_at_issue; p != r.wptr_at_issue; p++)
      if (int'(p) / 8 == line) useful = 1;
    if (!useful) err($sformatf("request for line %0d holds no unfetched work (rptr=%0d wptr=%0d)",
                               line, r.rptr_at_issue, r.wptr_at_issue));
  endfunction

  function void check_phase(uvm_phase phase);
    if (exp_q.size() != 0) err($sformatf("%0d published dwords were never delivered", exp_q.size()));
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("dwords delivered=%0d requests=%0d errors=%0d", n_dw, n_req, n_err), UVM_LOW)
  endfunction
endclass
