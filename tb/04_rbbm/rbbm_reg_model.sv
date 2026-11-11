// UVM register model (RAL) of the RBBM. Volatile registers (changed by hardware) are marked volatile so the
// mirror is never trusted for them; their values are checked by the cycle-accurate reference model instead.
class rbbm_reg_id extends uvm_reg;
  `uvm_object_utils(rbbm_reg_id)
  rand uvm_reg_field id;
  function new(string name = "rbbm_reg_id"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  virtual function void build();
    id = uvm_reg_field::type_id::create("id");
    id.configure(this, 32, 0, "RO", 0, 32'h6D47_5055, 1, 0, 1);
  endfunction
endclass

class rbbm_reg_ring_base extends uvm_reg;
  `uvm_object_utils(rbbm_reg_ring_base)
  uvm_reg_field zero;
  rand uvm_reg_field base;
  function new(string name = "rbbm_reg_ring_base"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  virtual function void build();
    zero = uvm_reg_field::type_id::create("zero");
    zero.configure(this, 5, 0, "RO", 0, 0, 1, 0, 0);
    base = uvm_reg_field::type_id::create("base");
    base.configure(this, 27, 5, "RW", 0, 0, 1, 1, 0);
  endfunction
endclass

// generic one-field register: width, access policy, volatile flag
class rbbm_reg_simple extends uvm_reg;
  `uvm_object_utils(rbbm_reg_simple)
  rand uvm_reg_field f;
  int w = 32; string acc = "RW"; bit vol = 0;
  function new(string name = "rbbm_reg_simple"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
  function void setup(int w, string acc, bit vol);
    this.w = w; this.acc = acc; this.vol = vol;
  endfunction
  virtual function void build();
    f = uvm_reg_field::type_id::create("f");
    f.configure(this, w, 0, acc, vol, 0, 1, (acc == "RW"), 1);
  endfunction
endclass

class rbbm_reg_block extends uvm_reg_block;
  `uvm_object_utils(rbbm_reg_block)
  rbbm_reg_id        ID;
  rbbm_reg_ring_base RING_BASE;
  rbbm_reg_simple    RING_WPTR, RING_RPTR, IRQ_STATUS, IRQ_MASK, BUSY_STATUS, HANG_TIMEOUT, SOFT_RESET;
  rbbm_reg_simple    PERF_SEL[4], PERF_CNT[4];
  function new(string name = "rbbm_reg_block"); super.new(name, UVM_NO_COVERAGE); endfunction

  function rbbm_reg_simple mk(string n, int w, string acc, bit vol, int off);
    rbbm_reg_simple r = rbbm_reg_simple::type_id::create(n);
    r.setup(w, acc, vol);
    r.configure(this);
    r.build();
    default_map.add_reg(r, off, (acc == "RO") ? "RO" : (acc == "WO") ? "WO" : "RW");
    return r;
  endfunction

  virtual function void build();
    default_map = create_map("apb_map", 0, 4, UVM_LITTLE_ENDIAN);
    ID = rbbm_reg_id::type_id::create("ID");
    ID.configure(this); ID.build();
    default_map.add_reg(ID, 'h000, "RO");
    RING_BASE = rbbm_reg_ring_base::type_id::create("RING_BASE");
    RING_BASE.configure(this); RING_BASE.build();
    default_map.add_reg(RING_BASE, 'h004, "RW");
    RING_WPTR    = mk("RING_WPTR",    10, "RW",  0, 'h008);
    RING_RPTR    = mk("RING_RPTR",    10, "RO",  1, 'h00C);
    IRQ_STATUS   = mk("IRQ_STATUS",    4, "W1C", 1, 'h010);
    IRQ_MASK     = mk("IRQ_MASK",      4, "RW",  0, 'h014);
    BUSY_STATUS  = mk("BUSY_STATUS",   8, "RO",  1, 'h018);
    HANG_TIMEOUT = mk("HANG_TIMEOUT", 32, "RW",  0, 'h01C);
    SOFT_RESET   = mk("SOFT_RESET",    1, "WO",  0, 'h020);
    for (int i = 0; i < 4; i++) begin
      PERF_SEL[i] = mk($sformatf("PERF_SEL%0d", i), 4,  "RW", 0, 'h040 + 8 * i);
      PERF_CNT[i] = mk($sformatf("PERF_CNT%0d", i), 32, "RW", 1, 'h044 + 8 * i);
    end
    lock_model();
  endfunction
endclass

class rbbm_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(rbbm_reg_adapter)
  function new(string name = "rbbm_reg_adapter");
    super.new(name);
    supports_byte_enable = 0;
    provides_responses = 0;
  endfunction
  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_item t = apb_item::type_id::create("t");
    t.addr  = rw.addr[11:0];
    t.write = (rw.kind == UVM_WRITE);
    t.wdata = rw.data;
    return t;
  endfunction
  virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
    apb_item t;
    if (!$cast(t, bus_item)) `uvm_fatal("ADAPT", "not an apb_item")
    rw.kind   = t.write ? UVM_WRITE : UVM_READ;
    rw.addr   = t.addr;
    rw.data   = t.write ? t.wdata : t.rdata;
    rw.status = t.slverr ? UVM_NOT_OK : UVM_IS_OK;
  endfunction
endclass
