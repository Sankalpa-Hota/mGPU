// One type 7 operation as the decoder hands it over: opcode plus payload dwords.
class sqe_op extends uvm_sequence_item;
  `uvm_object_utils(sqe_op)
  rand bit [6:0]  opcode;
  rand int        count;
  rand bit [31:0] arg0, arg1;
  rand int        gap;
  rand bit [7:0]  mask;
  rand int        extra;   // payload dwords beyond what the opcode needs
  int unknown_w = 0, max_gap = 2;
  bit [31:0] payload[];
  int  t_accept;   // filled by the monitor: cycle of the last payload dword

  constraint c_op    { opcode dist {7'h01 :/ 35, 7'h02 :/ 30, 7'h03 :/ 35 - unknown_w, [7'h04:7'h7F] :/ unknown_w}; }
  constraint c_extra { extra dist {0 :/ 85, [1:2] :/ 15}; }
  constraint c_count { count == ((opcode == 7'h02) ? 2 : 1) + extra; }
  constraint c_args  { opcode == 7'h01 -> arg0 inside {[1:64]};
                       opcode == 7'h02 -> arg0[1:0] == 2'b00;
                       opcode == 7'h03 -> arg0 == {24'h0, mask}; }
  constraint c_mask  { mask dist {8'h00 :/ 5, 8'hFF :/ 30, 8'h01 :/ 30, [8'h02:8'hFE] :/ 35}; }
  constraint c_gap   { gap inside {[0:max_gap]}; }

  function new(string name = "sqe_op");
    super.new(name);
  endfunction
  function void post_randomize();
    payload = new[count];
    foreach (payload[i]) payload[i] = (i == 0) ? arg0 : (i == 1) ? arg1 : $urandom;
  endfunction
  function string convert2string();
    string n = opcode == 1 ? "DISPATCH" : opcode == 2 ? "EVENT_WRITE" : opcode == 3 ? "WAIT_FOR_IDLE" : "UNKNOWN";
    return $sformatf("%s(op=%02h) arg0=%08h arg1=%08h count=%0d", n, opcode, arg0, arg1, count);
  endfunction
endclass

typedef enum {EV_DISPATCH, EV_WRITE, EV_IRQ, EV_DONE, EV_WORK_END, EV_BAD} sqe_ev_e;

// Any side effect observed on the pins, stamped with its cycle.
class sqe_event extends uvm_sequence_item;
  `uvm_object_utils(sqe_event)
  sqe_ev_e   kind;
  int        t;
  bit [31:0] num_wg;
  bit [31:0] addr;
  bit [255:0] wdata;
  bit [31:0] wstrb;
  int        t_ack;
  bit [7:0]  busy_prev;   // busy_in one cycle before this event
  int        work_id;
  function new(string name = "sqe_event");
    super.new(name);
  endfunction
endclass
