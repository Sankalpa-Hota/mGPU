// Reference model: an untimed, independent parser of the same dword stream. For every accepted dword it
// predicts the decoder output (register write, opcode dword, or the one-time bad-packet event).
class cp_ref_model extends uvm_component;
  `uvm_component_utils(cp_ref_model)
  uvm_analysis_imp #(cp_dw_item, cp_ref_model) in_imp;
  uvm_analysis_port #(cp_out_item) exp_ap;
  uvm_analysis_port #(cp_pkt_obs)  pkt_ap;

  typedef enum {M_HDR, M_T4, M_T7} mstate_e;
  mstate_e   st = M_HDR;
  int        remain;
  bit [17:0] reg_addr;
  bit [6:0]  op;
  bit        bad_seen;
  cp_pkt_obs cur;
  pkt_kind_e prev_kind = PKT_T4;
  int n_pkts[pkt_kind_e];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    in_imp = new("in_imp", this);
    exp_ap = new("exp_ap", this);
    pkt_ap = new("pkt_ap", this);
  endfunction

  function void close_pkt();
    cur.prev_kind = prev_kind;
    prev_kind = cur.kind;
    n_pkts[cur.kind]++;
    pkt_ap.write(cur);
    st = M_HDR;
  endfunction

  function void write(cp_dw_item d);
    cp_out_item e;
    case (st)
      M_HDR: begin
        cur = cp_pkt_obs::type_id::create("cur");
        cur.stalled = d.stalled;
        if (d.data[31:28] == 4'h4) begin
          cur.kind = PKT_T4;
          reg_addr = d.data[25:8];
          remain   = d.data[6:0];
          cur.count = remain;
          if (remain == 0) close_pkt(); else st = M_T4;
        end else if (d.data[31:28] == 4'h7) begin
          cur.kind  = PKT_T7;
          op        = d.data[22:16];
          remain    = d.data[13:0];
          cur.count = remain;
          cur.opcode = op;
          if (remain == 0) close_pkt(); else st = M_T7;
        end else begin
          cur.kind = PKT_BAD;
          if (!bad_seen) begin
            e = cp_out_item::type_id::create("e");
            e.kind = OUT_BAD;
            exp_ap.write(e);
          end
          bad_seen = 1;
          close_pkt();
        end
      end
      M_T4: begin
        cur.stalled |= d.stalled;
        e = cp_out_item::type_id::create("e");
        e.kind = OUT_REG; e.addr = reg_addr; e.data = d.data;
        exp_ap.write(e);
        if (reg_addr == 18'h3FFFF) cur.reg_wrap = 1;
        reg_addr = reg_addr + 1;
        remain--;
        if (remain == 0) close_pkt();
      end
      M_T7: begin
        cur.stalled |= d.stalled;
        e = cp_out_item::type_id::create("e");
        e.kind = OUT_OP; e.op = op; e.data = d.data; e.last = (remain == 1);
        exp_ap.write(e);
        remain--;
        if (remain == 0) close_pkt();
      end
    endcase
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MODEL", $sformatf("packets parsed: T4=%0d T7=%0d BAD=%0d (mid-packet at end: %0b)",
              n_pkts[PKT_T4], n_pkts[PKT_T7], n_pkts[PKT_BAD], st != M_HDR), UVM_LOW)
  endfunction
endclass
