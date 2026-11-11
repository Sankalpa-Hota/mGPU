typedef enum {PKT_T4, PKT_T7, PKT_BAD} pkt_kind_e;

// One PM4 packet as the sequence creates it.
class cp_pkt extends uvm_sequence_item;
  `uvm_object_utils(cp_pkt)
  rand pkt_kind_e kind;
  rand bit [17:0] reg_addr;
  rand bit [6:0]  opcode;
  rand int        count;
  rand bit [3:0]  bad_type;
  rand int        gap;
  bit [31:0]      payload[];
  int t4_w = 45, t7_w = 45, bad_w = 0, zero_w = 5, max_w = 3, wrap_w = 3, max_gap = 0;

  constraint c_kind  { kind dist {PKT_T4 := t4_w, PKT_T7 := t7_w, PKT_BAD := bad_w}; }
  constraint c_bad   { !(bad_type inside {4'h4, 4'h7}); }
  constraint c_count {
    kind == PKT_BAD -> count == 0;
    kind == PKT_T4  -> count dist {0 := zero_w, [1:8] :/ 70, [9:126] :/ 20, 127 := max_w};
    kind == PKT_T7  -> count dist {0 := zero_w, [1:8] :/ 80, [9:40] :/ 15};
  }
  constraint c_reg   { reg_addr dist {[18'h3FF80:18'h3FFFF] :/ wrap_w, [0:18'h3FF7F] :/ 100 - wrap_w}; }
  constraint c_op    { opcode dist {[1:3] :/ 60, [0:127] :/ 40}; }
  constraint c_gap   { gap inside {[0:max_gap]}; }

  function new(string name = "cp_pkt");
    super.new(name);
  endfunction

  function void post_randomize();
    payload = new[count];
    foreach (payload[i]) payload[i] = $urandom;
  endfunction

  function bit [31:0] header();
    case (kind)
      PKT_T4:  return {4'h4, 2'b00, reg_addr, 1'b0, 7'(count)};
      PKT_T7:  return {4'h7, 2'b00, 3'b000, opcode, 2'b00, 14'(count)};
      default: return {bad_type, 28'($urandom)};
    endcase
  endfunction

  function string convert2string();
    return $sformatf("%s reg=%05h op=%02h count=%0d", kind.name(), reg_addr, opcode, count);
  endfunction
endclass

// One accepted input dword, as the monitor saw it.
class cp_dw_item extends uvm_sequence_item;
  `uvm_object_utils(cp_dw_item)
  bit [31:0] data;
  bit        stalled;   // dword waited at least one cycle for ready
  function new(string name = "cp_dw_item");
    super.new(name);
  endfunction
endclass

typedef enum {OUT_REG, OUT_OP, OUT_BAD} out_kind_e;

// One observed output event of the decoder.
class cp_out_item extends uvm_sequence_item;
  `uvm_object_utils(cp_out_item)
  out_kind_e kind;
  bit [17:0] addr;
  bit [6:0]  op;
  bit [31:0] data;
  bit        last;
  function new(string name = "cp_out_item");
    super.new(name);
  endfunction
  function string convert2string();
    case (kind)
      OUT_REG: return $sformatf("REG  addr=%05h data=%08h", addr, data);
      OUT_OP:  return $sformatf("OP   op=%02h data=%08h last=%0b", op, data, last);
      default: return "BAD_PKT raised";
    endcase
  endfunction
  function bit same(cp_out_item o);
    if (kind != o.kind) return 0;
    if (kind == OUT_REG) return addr == o.addr && data == o.data;
    if (kind == OUT_OP)  return op == o.op && data == o.data && last == o.last;
    return 1;
  endfunction
endclass

// Packet-level view rebuilt by the reference model, used by coverage.
class cp_pkt_obs extends uvm_object;
  `uvm_object_utils(cp_pkt_obs)
  pkt_kind_e kind;
  int        count;
  bit [6:0]  opcode;
  bit        stalled;
  bit        reg_wrap;
  bit        back_to_back;
  pkt_kind_e prev_kind;
  function new(string name = "cp_pkt_obs");
    super.new(name);
  endfunction
endclass
