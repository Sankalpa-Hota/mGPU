// Raw APB traffic, including illegal addresses and writes to read-only registers (RAL cannot send those).
class rbbm_raw_access_seq extends uvm_sequence #(apb_item);
  `uvm_object_utils(rbbm_raw_access_seq)
  int n = 200;
  function new(string name = "rbbm_raw_access_seq");
    super.new(name);
  endfunction
  task body();
    repeat (n) begin
      apb_item t = apb_item::type_id::create("t");
      start_item(t);
      if (!t.randomize() with { addr inside {[12'h000:12'h07C], [12'hF00:12'hFFC]}; }) `uvm_fatal("RAND", "apb")
      finish_item(t);
    end
  endtask
endclass

// Register-model based sequences: they talk in register names, not addresses.
class rbbm_reg_base_seq extends uvm_sequence;
  `uvm_object_utils(rbbm_reg_base_seq)
  rbbm_reg_block rm;
  uvm_status_e st;
  uvm_reg_data_t v;
  function new(string name = "rbbm_reg_base_seq");
    super.new(name);
  endfunction
endclass

// Interrupt service loop like a driver's ISR: read status, write back what was read (W1C), sometimes
// re-program the mask.
class rbbm_isr_seq extends rbbm_reg_base_seq;
  `uvm_object_utils(rbbm_isr_seq)
  int n = 150;
  function new(string name = "rbbm_isr_seq");
    super.new(name);
  endfunction
  task body();
    rm.IRQ_MASK.write(st, 4'hF);
    repeat (n) begin
      rm.IRQ_STATUS.read(st, v);
      if ($urandom_range(3) == 0) v = $urandom_range(15);
      rm.IRQ_STATUS.write(st, v);
      if ($urandom_range(9) == 0) rm.IRQ_MASK.write(st, $urandom_range(15));
    end
  endtask
endclass

class rbbm_hang_seq extends rbbm_reg_base_seq;
  `uvm_object_utils(rbbm_hang_seq)
  function new(string name = "rbbm_hang_seq");
    super.new(name);
  endfunction
  task body();
    rm.IRQ_MASK.write(st, 4'h8);
    repeat (12) begin
      rm.HANG_TIMEOUT.write(st, $urandom_range(20, 2));
      repeat (15) begin
        rm.IRQ_STATUS.read(st, v);
        if (v[3]) rm.IRQ_STATUS.write(st, 4'h8);
      end
    end
    rm.HANG_TIMEOUT.write(st, 0);
  endtask
endclass

class rbbm_perf_seq extends rbbm_reg_base_seq;
  `uvm_object_utils(rbbm_perf_seq)
  function new(string name = "rbbm_perf_seq");
    super.new(name);
  endfunction
  task body();
    repeat (40) begin
      int i = $urandom_range(3);
      case ($urandom_range(3))
        0: rm.PERF_SEL[i].write(st, $urandom_range(15));
        1: rm.PERF_CNT[i].write(st, $urandom_range(3) == 0 ? 32'hFFFF_FFF0 : $urandom);
        default: rm.PERF_CNT[i].read(st, v);
      endcase
    end
  endtask
endclass

// Static registers: write random values then mirror with check (the RAL compares read data with its mirror).
class rbbm_static_reg_seq extends rbbm_reg_base_seq;
  `uvm_object_utils(rbbm_static_reg_seq)
  function new(string name = "rbbm_static_reg_seq");
    super.new(name);
  endfunction
  task body();
    repeat (20) begin
      rm.RING_BASE.write(st, $urandom);
      rm.RING_WPTR.write(st, $urandom);
      rm.IRQ_MASK.write(st, $urandom);
      rm.HANG_TIMEOUT.write(st, $urandom_range(3) == 0 ? 0 : $urandom_range(1000, 50));
      rm.PERF_SEL[$urandom_range(3)].write(st, $urandom);
      rm.RING_BASE.mirror(st, UVM_CHECK);
      rm.RING_WPTR.mirror(st, UVM_CHECK);
      rm.IRQ_MASK.mirror(st, UVM_CHECK);
      rm.HANG_TIMEOUT.mirror(st, UVM_CHECK);
      rm.ID.mirror(st, UVM_CHECK);
      foreach (rm.PERF_SEL[i]) rm.PERF_SEL[i].mirror(st, UVM_CHECK);
      if ($urandom_range(4) == 0) rm.SOFT_RESET.write(st, 1);
    end
  endtask
endclass
