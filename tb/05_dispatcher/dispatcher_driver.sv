// Plays the CP: register writes on the register bus, then the DISPATCH handshake from the SQE.
class dispatcher_driver extends uvm_driver #(disp_kernel);
  `uvm_component_utils(dispatcher_driver)
  disp_vif_t vif;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(disp_vif_t)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "no vif")
  endfunction
  task reg_write(bit [17:0] a, bit [31:0] d);
    vif.reg_wr_en = 1; vif.reg_wr_addr = a; vif.reg_wr_data = d;
    @(posedge vif.clk); #1;
    vif.reg_wr_en = 0;
  endtask
  task run_phase(uvm_phase phase);
    vif.reg_wr_en = 0; vif.disp_valid = 0; vif.disp_num_wg = 0; vif.reg_wr_addr = 0; vif.reg_wr_data = 0;
    wait (vif.rst_n === 1);
    @(posedge vif.clk); #1;
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.gap) begin @(posedge vif.clk); #1; end
      reg_write(18'h100, req.pc);
      reg_write(18'h101, req.nwarps_raw);
      reg_write(18'h102, req.arg);
      vif.disp_valid = 1; vif.disp_num_wg = req.num_wg;
      do @(negedge vif.clk); while (!vif.disp_ready);
      @(posedge vif.clk); #1;
      vif.disp_valid = 0;
      if (req.rewrite_cfg) begin
        reg_write(18'h100, $urandom & ~32'h3);
        reg_write(18'h101, $urandom_range(6));
        reg_write(18'h102, $urandom);
      end
      seq_item_port.item_done();
    end
  endtask
endclass
