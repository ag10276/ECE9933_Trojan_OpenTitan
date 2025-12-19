`timescale 1ns / 1ps

module tb_aes_trojan_detect;

  // DUT Interface Signals
  logic          clk;
  logic          reset_n;
  logic          cs;
  logic          we;
  logic [7 : 0]  address;
  logic [31 : 0] write_data;
  logic [31 : 0] read_data;

  // AES Register Map (from aes.v)
  localparam ADDR_CTRL        = 8'h08;
  localparam CTRL_INIT_BIT    = 0;
  localparam CTRL_NEXT_BIT    = 1;

  localparam ADDR_STATUS      = 8'h09;
  localparam STATUS_READY_BIT = 0;
  localparam STATUS_VALID_BIT = 1;

  localparam ADDR_CONFIG      = 8'h0a;
  localparam CTRL_ENCDEC_BIT  = 0;
  
  localparam ADDR_KEY0        = 8'h10;
  localparam ADDR_BLOCK0      = 8'h20;
  
  // Trojan Trigger Count
  localparam TROJAN_LIMIT = 862;

  // Instantiate the Device Under Test (DUT)
  aes dut (
    .clk(clk),
    .reset_n(reset_n),
    .cs(cs),
    .we(we),
    .address(address),
    .write_data(write_data),
    .read_data(read_data)
  );


  // 1. --- Clock Generator ---
  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 100MHz clock
  end


  // 2. --- Main Test Sequence ---
  initial begin
    $display("Starting AES Trojan Detection Test...");
    
    // Reset the DUT
    reset_dut();
    
    // --- Part 1: Trigger the Trojan Counter ---
    $display("Priming the trojan counter... This will take %0d cycles.", TROJAN_LIMIT);
    
    repeat (TROJAN_LIMIT) begin
      // Set to encryption mode
      write_reg(ADDR_CONFIG, (1 << CTRL_ENCDEC_BIT));
      
      // Trigger key initialization (init=1)
      write_reg(ADDR_CTRL, (1 << CTRL_INIT_BIT));
      
      // Wait for the core to be ready again
      poll_ready();
      
      // Clear control register
      write_reg(ADDR_CTRL, 0);
    end
    
    $display("Trojan counter should now be at %0d.", TROJAN_LIMIT);
    $display("Attempting one final encryption to test for DoS...");

    // --- Part 2: Test for DoS Payload ---
    
    // Write a dummy key and block
    write_reg(ADDR_KEY0, 32'hDEADBEEF);
    write_reg(ADDR_BLOCK0, 32'hCAFEFEED);
    
    // Set to encryption mode
    write_reg(ADDR_CONFIG, (1 << CTRL_ENCDEC_BIT));
    
    // 1. Initialize the key (This is the 863rd init, it will be blocked)
    write_reg(ADDR_CTRL, (1 << CTRL_INIT_BIT));
    poll_ready(); 
    write_reg(ADDR_CTRL, 0);

    // 2. Start the encryption (This 'next' signal will be blocked)
    write_reg(ADDR_CTRL, (1 << CTRL_NEXT_BIT));

    // 3. Fork a timeout and a success check
    fork
      // Process A: Wait for a valid result (success)
      begin : poll_for_valid
        logic [31:0] status_val;
        // Read the status register
        read_reg(ADDR_STATUS, status_val);
        // Wait while the valid bit is 0
        while (status_val[STATUS_VALID_BIT] == 0) begin
          @(posedge clk);
          read_reg(ADDR_STATUS, status_val);
        end
        
        // If we get here, the trojan failed or is not present
        $error("TEST FAILED: Module produced a valid result. Trojan was not detected.");
        $finish;
      end

      // Process B: Timeout (failure, which means trojan was detected)
      begin : timeout
        repeat (1000) @(posedge clk); // Wait 1000 cycles
        
        // If we get here, poll_for_valid did not finish
        $display("TEST PASSED: Timed out waiting for valid result.");
        $display("DoS Trojan successfully detected.");
        $finish;
      end
      
    join
  end

  // 3. --- Helper Tasks ---

  // Task to reset the DUT
  task reset_dut;
    @(negedge clk);
    reset_n = 1'b0;
    cs      = 1'b0;
    we      = 1'b0;
    @(posedge clk);
    @(posedge clk);
    reset_n = 1'b1;
    $display("Reset complete.");
  endtask
  
  // Task to write to a register
  task write_reg(input [7:0] w_addr, input [31:0] w_data);
    @(posedge clk);
    cs         = 1'b1;
    we         = 1'b1;
    address    = w_addr;
    write_data = w_data;
    @(posedge clk);
    cs         = 1'b0;
    we         = 1'b0;
  endtask

  // Task to read from a register
  // **FIX 2**: Added 'logic' to the output port declaration
  task read_reg(input [7:0] r_addr, output logic [31:0] r_data);
    @(posedge clk);
    cs         = 1'b1;
    we         = 1'b0;
    address    = r_addr;
    @(posedge clk);
    r_data     = read_data;
    cs         = 1'b0;
  endtask
  
  // Task to poll the ready bit
  // **FIX 1**: Replaced do...while with a standard while loop
  task poll_ready;
    logic [31:0] status_val;
    read_reg(ADDR_STATUS, status_val); // Initial read
    while (status_val[STATUS_READY_BIT] == 0) begin
      @(posedge clk);
      read_reg(ADDR_STATUS, status_val); // Poll until ready
    end
  endtask

endmodule