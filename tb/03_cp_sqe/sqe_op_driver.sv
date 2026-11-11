// Plays the packet decoder: sends each payload dword with op_valid, op_last on the final one, obeying op_ready.
class sqe_op_driver extends uvm_driver #(sqe_op);
  `uvm_component_utils(sqe_op_driver)
  sqe_vif_t vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(sqe_vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "no vif")
  endfunction
  task run_phase(uvm_phase phase);
    vif.op_valid = 0; vif.op_last = 0; vif.op_code = 0; vif.op_data = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      `uvm_info("DRV", req.convert2string(), UVM_HIGH)
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      foreach (req.payload[i]) begin
        vif.op_valid = 1;
        vif.op_code  = req.opcode;
        vif.op_data  = req.payload[i];
        vif.op_last  = (i == req.payload.size() - 1);
        do @(negedge vif.clk); while (!vif.op_ready);
        @(posedge vif.clk); #1;
      end
      vif.op_valid = 0; vif.op_last = 0;
      seq_item_port.item_done();
    end
  endtask
endclass
