`uvm_analysis_imp_decl(_op)
`uvm_analysis_imp_decl(_ev)
`uvm_analysis_imp_decl(_work)

// The SQE runs one operation at a time, so every side effect between "op accepted" and "op_done" must belong
// to that op. Per opcode:
//   DISPATCH     exactly one dispatch handshake carrying arg0, nothing else
//   EVENT_WRITE  exactly one write: line address, byte strobes and data lane all derived from arg0/arg1;
//                exactly one IRQ, strictly after the write ack (software reads the fence when the IRQ arrives)
//   WFI          done only when every selected busy bit was low, and every job started by an earlier
//                DISPATCH has really ended (this is what catches a too-early WFI)
//   unknown      no side effect; bad_op rises on the first one
class sqe_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(sqe_scoreboard)
  uvm_analysis_imp_op   #(sqe_op,    sqe_scoreboard) op_imp;
  uvm_analysis_imp_ev   #(sqe_event, sqe_scoreboard) ev_imp;
  uvm_analysis_imp_work #(sqe_event, sqe_scoreboard) work_imp;

  sqe_op    cur;
  sqe_event fx[$];
  int       disp_start[int];
  int       work_end[int];
  int       n_disp, n_ops, n_err;
  bit       bad_seen;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    op_imp = new("op_imp", this);
    ev_imp = new("ev_imp", this);
    work_imp = new("work_imp", this);
  endfunction
  function void err(string s);
    n_err++;
    `uvm_error("SB", s)
  endfunction

  function void write_op(sqe_op o);
    if (cur != null) err($sformatf("op %s accepted while %s still executing", o.convert2string(), cur.convert2string()));
    cur = o;
    fx.delete();
  endfunction

  function void write_work(sqe_event e);
    work_end[e.work_id] = e.t;
  endfunction

  function void write_ev(sqe_event e);
    if (e.kind == EV_DISPATCH) begin
      disp_start[n_disp] = e.t;
      e.work_id = n_disp++;
    end
    if (e.kind != EV_DONE) begin
      if (cur == null) begin
        err($sformatf("side effect %s at cycle %0d with no operation in progress", e.kind.name(), e.t));
        return;
      end
      fx.push_back(e);
      return;
    end
    if (cur == null) begin
      err($sformatf("op_done at cycle %0d with no operation in progress", e.t));
      return;
    end
    check_done(e);
    n_ops++;
    cur = null;
  endfunction

  function int count(sqe_ev_e k);
    int n = 0;
    foreach (fx[i]) if (fx[i].kind == k) n++;
    return n;
  endfunction

  function void check_done(sqe_event d);
    string op = cur.convert2string();
    case (cur.opcode)
      7'h01: begin
        if (count(EV_DISPATCH) != 1 || fx.size() != 1) err($sformatf("%s: expected exactly one dispatch, saw %0d effects", op, fx.size()));
        else if (fx[0].num_wg != cur.arg0) err($sformatf("%s: dispatched %0d workgroups", op, fx[0].num_wg));
      end
      7'h02: begin
        sqe_event w, q;
        int off = cur.arg0[4:2];
        foreach (fx[i]) if (fx[i].kind == EV_WRITE) w = fx[i]; else if (fx[i].kind == EV_IRQ) q = fx[i];
        if (count(EV_WRITE) != 1 || count(EV_IRQ) != 1 || fx.size() != 2)
          err($sformatf("%s: expected one write and one IRQ, saw %0d writes %0d IRQs", op, count(EV_WRITE), count(EV_IRQ)));
        else begin
          if (w.addr != {cur.arg0[31:5], 5'b0}) err($sformatf("%s: write line address %08h", op, w.addr));
          if (w.wstrb != (32'hF << (4 * off))) err($sformatf("%s: byte strobes %08h, expected %08h", op, w.wstrb, 32'hF << (4 * off)));
          if (w.wdata[32*off +: 32] != cur.arg1) err($sformatf("%s: data lane %0d holds %08h", op, off, w.wdata[32*off +: 32]));
          if (q.t <= w.t_ack) err($sformatf("%s: IRQ at cycle %0d but write ack only at cycle %0d", op, q.t, w.t_ack));
        end
      end
      7'h03: begin
        if (fx.size() != 0) err($sformatf("%s: unexpected side effects", op));
        if ((d.busy_prev & cur.arg0[7:0]) != 0)
          err($sformatf("%s: finished while busy_in=%02h", op, d.busy_prev));
        if (cur.arg0[0])
          foreach (disp_start[id])
            if (disp_start[id] < cur.t_accept && (!work_end.exists(id) || work_end[id] >= d.t))
              err($sformatf("%s: finished at cycle %0d but dispatch #%0d (cycle %0d) was still running", op, d.t, id, disp_start[id]));
      end
      default: begin
        if (fx.size() > (bad_seen ? 0 : 1) || (!bad_seen && count(EV_BAD) != 1))
          err($sformatf("%s: unknown opcode must only raise bad_op once", op));
        bad_seen = 1;
      end
    endcase
  endfunction

  function void check_phase(uvm_phase phase);
    if (cur != null) err($sformatf("operation %s never finished", cur.convert2string()));
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("operations completed=%0d dispatches=%0d errors=%0d", n_ops, n_disp, n_err), UVM_LOW)
  endfunction
endclass
