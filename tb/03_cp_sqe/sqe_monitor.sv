// Samples every cycle at the falling edge. Publishes completed ops (at their last payload dword) and every
// side effect (dispatch handshake, memory write with its ack cycle, IRQ, op_done, bad_op rising).
class sqe_monitor extends uvm_monitor;
  `uvm_component_utils(sqe_monitor)
  sqe_vif_t vif;
  uvm_analysis_port #(sqe_op)    op_ap;
  uvm_analysis_port #(sqe_event) ev_ap;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    op_ap = new("op_ap", this);
    ev_ap = new("ev_ap", this);
    void'(uvm_config_db#(sqe_vif_t)::get(this, "", "vif", vif));
  endfunction
  function sqe_event ev(sqe_ev_e k, int t, bit [7:0] bp);
    sqe_event e = sqe_event::type_id::create("e");
    e.kind = k; e.t = t; e.busy_prev = bp;
    return e;
  endfunction
  task run_phase(uvm_phase phase);
    bit [31:0] pl[$];
    bit [7:0]  busy_prev = 0;
    bit        bad_q = 0;
    sqe_event  wr;
    forever begin
      int t;
      @(negedge vif.clk);
      t = $time / 10;
      if (vif.rst_n !== 1) continue;
      if (vif.bad_op && !bad_q) ev_ap.write(ev(EV_BAD, t, busy_prev));
      bad_q = vif.bad_op;
      if (vif.irq)     ev_ap.write(ev(EV_IRQ, t, busy_prev));
      if (vif.op_done) ev_ap.write(ev(EV_DONE, t, busy_prev));
      if (vif.disp_valid && vif.disp_ready) begin
        sqe_event e = ev(EV_DISPATCH, t, busy_prev);
        e.num_wg = vif.disp_num_wg;
        ev_ap.write(e);
      end
      if (wr != null && vif.mrsp_valid) begin
        wr.t_ack = t;
        ev_ap.write(wr);
        wr = null;
      end
      if (vif.mreq_valid && vif.mreq_ready) begin
        wr = ev(EV_WRITE, t, busy_prev);
        wr.addr = vif.mreq_addr; wr.wdata = vif.mreq_wdata; wr.wstrb = vif.mreq_wstrb;
      end
      if (vif.op_valid && vif.op_ready) begin
        pl.push_back(vif.op_data);
        if (vif.op_last) begin
          sqe_op o = sqe_op::type_id::create("o");
          o.opcode = vif.op_code;
          o.count  = pl.size();
          o.payload = new[pl.size()];
          foreach (pl[i]) o.payload[i] = pl[i];
          o.arg0 = pl[0];
          o.arg1 = (pl.size() > 1) ? pl[1] : 0;
          o.t_accept = t;
          op_ap.write(o);
          pl.delete();
        end
      end
      busy_prev = vif.busy_in;
    end
  endtask
endclass
