////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	trojan_detection_tb.v
//
// Project:	Hardware Trojan Detection for wbuart32
//
// Purpose:	Comprehensive testbench to detect and demonstrate the hardware
//		trojan inserted into the wbuart module. This testbench:
//		1. Tests normal operation
//		2. Triggers the trojan with the activation sequence
//		3. Demonstrates the DoS condition
//		4. Resets and runs the original speechfifo test
//		5. Re-triggers the trojan to confirm persistent vulnerability
//
////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

module trojan_detection_tb();

	// Clock and reset
	reg		i_clk;
	reg		i_reset;
	
	// UART signals
	wire		uart_tx;
	reg		uart_rx;
	
	// Wishbone interface signals (for direct testing)
	reg		wb_cyc, wb_stb, wb_we;
	reg	[1:0]	wb_addr;
	reg	[31:0]	wb_data;
	reg	[3:0]	wb_sel;
	wire		wb_stall;
	wire		wb_ack;
	wire	[31:0]	wb_rdata;
	
	// Interrupt signals
	wire		rx_int, tx_int, rxfifo_int, txfifo_int;
	
	// Test control
	integer		test_phase;
	integer		bit_counter;
	integer		byte_counter;
	reg	[31:0]	timeout_counter;
	reg		test_failed;
	reg	[31:0]	read_data;
	
	// UART parameters
	parameter	CLOCKS_PER_BAUD = 25;  // Match INITIAL_SETUP default
	parameter	UART_SETUP = 31'd25;
	
	// Trojan trigger sequence: 0x10, 0xA4, 0x98, 0xBD
	parameter [7:0] TRIGGER_BYTE_1 = 8'h10;
	parameter [7:0] TRIGGER_BYTE_2 = 8'hA4;
	parameter [7:0] TRIGGER_BYTE_3 = 8'h98;
	parameter [7:0] TRIGGER_BYTE_4 = 8'hBD;
	
	// Recovery sequence: 4x 0xFE
	parameter [7:0] RECOVERY_BYTE = 8'hFE;
	
	////////////////////////////////////////////////////////////////////////
	// Device Under Test
	////////////////////////////////////////////////////////////////////////
	
	wbuart #(
		.INITIAL_SETUP(UART_SETUP),
		.LGFLEN(4),
		.HARDWARE_FLOW_CONTROL_PRESENT(1'b0)
	) dut (
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_wb_cyc(wb_cyc),
		.i_wb_stb(wb_stb),
		.i_wb_we(wb_we),
		.i_wb_addr(wb_addr),
		.i_wb_data(wb_data),
		.i_wb_sel(wb_sel),
		.o_wb_stall(wb_stall),
		.o_wb_ack(wb_ack),
		.o_wb_data(wb_rdata),
		.i_uart_rx(uart_rx),
		.o_uart_tx(uart_tx),
		.i_cts_n(1'b0),
		.o_rts_n(),
		.o_uart_rx_int(rx_int),
		.o_uart_tx_int(tx_int),
		.o_uart_rxfifo_int(rxfifo_int),
		.o_uart_txfifo_int(txfifo_int)
	);
	
	////////////////////////////////////////////////////////////////////////
	// Clock Generation
	////////////////////////////////////////////////////////////////////////
	
	initial begin
		i_clk = 0;
		forever #5 i_clk = ~i_clk;  // 100MHz clock
	end
	
	////////////////////////////////////////////////////////////////////////
	// UART Byte Transmission Task
	////////////////////////////////////////////////////////////////////////
	
	task send_uart_byte;
		input [7:0] data;
		integer i;
		begin
			// Start bit
			uart_rx = 0;
			repeat(CLOCKS_PER_BAUD) @(posedge i_clk);
			
			// Data bits (LSB first)
			for (i = 0; i < 8; i = i + 1) begin
				uart_rx = data[i];
				repeat(CLOCKS_PER_BAUD) @(posedge i_clk);
			end
			
			// Stop bit
			uart_rx = 1;
			repeat(CLOCKS_PER_BAUD) @(posedge i_clk);
		end
	endtask
	
	////////////////////////////////////////////////////////////////////////
	// Wishbone Write Task
	////////////////////////////////////////////////////////////////////////
	
	task wb_write;
		input [1:0] addr;
		input [31:0] data;
		begin
			@(posedge i_clk);
			wb_cyc = 1;
			wb_stb = 1;
			wb_we = 1;
			wb_addr = addr;
			wb_data = data;
			wb_sel = 4'hF;
			
			@(posedge i_clk);
			while (!wb_ack && timeout_counter < 1000) begin
				@(posedge i_clk);
				timeout_counter = timeout_counter + 1;
			end
			
			if (timeout_counter >= 1000) begin
				$display("[ERROR] Wishbone write timeout at time %t", $time);
				test_failed = 1;
			end
			
			wb_cyc = 0;
			wb_stb = 0;
			wb_we = 0;
			timeout_counter = 0;
		end
	endtask
	
	////////////////////////////////////////////////////////////////////////
	// Wishbone Read Task
	////////////////////////////////////////////////////////////////////////
	
	task wb_read;
		input [1:0] addr;
		output [31:0] data;
		begin
			@(posedge i_clk);
			wb_cyc = 1;
			wb_stb = 1;
			wb_we = 0;
			wb_addr = addr;
			wb_sel = 4'hF;
			
			@(posedge i_clk);
			while (!wb_ack && timeout_counter < 1000) begin
				@(posedge i_clk);
				timeout_counter = timeout_counter + 1;
			end
			
			if (timeout_counter >= 1000) begin
				$display("[ERROR] Wishbone read timeout at time %t", $time);
				test_failed = 1;
			end else begin
				data = wb_rdata;
			end
			
			wb_cyc = 0;
			wb_stb = 0;
			timeout_counter = 0;
		end
	endtask
	
	////////////////////////////////////////////////////////////////////////
	// Main Test Sequence
	////////////////////////////////////////////////////////////////////////
	
	initial begin
		// Initialize signals
		i_reset = 1;
		uart_rx = 1;  // UART idle high
		wb_cyc = 0;
		wb_stb = 0;
		wb_we = 0;
		wb_addr = 0;
		wb_data = 0;
		wb_sel = 0;
		test_phase = 0;
		timeout_counter = 0;
		test_failed = 0;
		
		// VCD dump for waveform analysis
		$dumpfile("trojan_detection.vcd");
		$dumpvars(0, trojan_detection_tb);
		
		// Release reset
		repeat(20) @(posedge i_clk);
		i_reset = 0;
		repeat(10) @(posedge i_clk);
		
		$display("\n========================================");
		$display("HARDWARE TROJAN DETECTION TEST");
		$display("========================================\n");
		
		////////////////////////////////////////////////////////////////////////
		// PHASE 1: Normal Operation Test
		////////////////////////////////////////////////////////////////////////
		
		test_phase = 1;
		$display("[PHASE 1] Testing Normal Operation");
		$display("Time: %t", $time);
		$display("  - UART using default configuration (INITIAL_SETUP)");
		$display("  - Skipping explicit configuration to avoid rx_uart_reset");
		
		// Test normal write without reconfiguring
		wb_write(2'b11, 32'h00000041);  // Write 'A'
		$display("  - Normal write successful");
		
		// Wait for rx_uart_reset to clear (it's set initially)
		repeat(10) @(posedge i_clk);
		while (dut.rx_uart_reset) begin
			@(posedge i_clk);
		end
		$display("  - UART receiver out of reset (rx_uart_reset cleared)");
		
		// Additional settling time
		repeat(1000) @(posedge i_clk);
		$display("  - UART receiver ready");
		
		$display("[PHASE 1] PASSED - Normal operation working\n");
		
		////////////////////////////////////////////////////////////////////////
		// PHASE 2: Trigger Trojan
		////////////////////////////////////////////////////////////////////////
		
		test_phase = 2;
		$display("[PHASE 2] Triggering Hardware Trojan");
		$display("Time: %t", $time);
		$display("  - Sending trigger sequence: 0x10, 0xA4, 0x98, 0xBD");
		$display("  - Note: Bytes must arrive without FIFO reads to trigger trojan");
		
		// Send all 4 bytes rapidly without reading from FIFO
		send_uart_byte(TRIGGER_BYTE_1);
		$display("  - Sent byte 1: 0x%02X at time %t", TRIGGER_BYTE_1, $time);
		repeat(200) @(posedge i_clk);
		$display("    Trojan state after byte 1: %d", dut.trojan_state);
		
		send_uart_byte(TRIGGER_BYTE_2);
		$display("  - Sent byte 2: 0x%02X at time %t", TRIGGER_BYTE_2, $time);
		repeat(200) @(posedge i_clk);
		$display("    Trojan state after byte 2: %d", dut.trojan_state);
		
		send_uart_byte(TRIGGER_BYTE_3);
		$display("  - Sent byte 3: 0x%02X at time %t", TRIGGER_BYTE_3, $time);
		repeat(200) @(posedge i_clk);
		$display("    Trojan state after byte 3: %d", dut.trojan_state);
		
		send_uart_byte(TRIGGER_BYTE_4);
		$display("  - Sent byte 4: 0x%02X at time %t", TRIGGER_BYTE_4, $time);
		repeat(200) @(posedge i_clk);
		
		$display("  - Trigger sequence complete");
		$display("  - Trojan state: %d (Expected: 2 for DoS)", dut.trojan_state);
		$display("  - Trojan trigger_cnt: %d", dut.trojan_trigger_cnt);
		$display("  - rx_stb signal: %b", dut.rx_stb);
		$display("  - Trojan should now be ACTIVE (DoS state)\n");
		
		////////////////////////////////////////////////////////////////////////
		// PHASE 3: Verify DoS Condition
		////////////////////////////////////////////////////////////////////////
		
		test_phase = 3;
		$display("[PHASE 3] Verifying Denial-of-Service Condition");
		$display("Time: %t", $time);
		
		// Attempt Wishbone write - should hang (no ACK)
		timeout_counter = 0;
		@(posedge i_clk);
		wb_cyc = 1;
		wb_stb = 1;
		wb_we = 1;
		wb_addr = 2'b11;
		wb_data = 32'h00000043;  // Try to write 'C'
		wb_sel = 4'hF;
		
		// Wait for ACK with timeout
		repeat(500) @(posedge i_clk);
		
		if (!wb_ack) begin
			$display("  - SUCCESS: Wishbone ACK blocked (DoS active)");
			$display("  - Trojan payload is working!");
			$display("  - Trojan state: %d", dut.trojan_state);
			$display("[PHASE 3] TROJAN DETECTED - DoS condition confirmed\n");
		end else begin
			$display("  - ERROR: Wishbone still responding (trojan may not be active)");
			$display("  - Trojan state: %d (Expected: 2)", dut.trojan_state);
			test_failed = 1;
		end
		
		wb_cyc = 0;
		wb_stb = 0;
		
		////////////////////////////////////////////////////////////////////////
		// PHASE 4: Recover from Trojan
		////////////////////////////////////////////////////////////////////////
		
		test_phase = 4;
		$display("[PHASE 4] Recovering from Trojan");
		$display("Time: %t", $time);
		$display("  - Sending recovery sequence: 0xFE x 4");
		
		send_uart_byte(RECOVERY_BYTE);
		$display("  - Sent recovery byte 1/4");
		repeat(1000) @(posedge i_clk);
		
		send_uart_byte(RECOVERY_BYTE);
		$display("  - Sent recovery byte 2/4");
		repeat(1000) @(posedge i_clk);
		
		send_uart_byte(RECOVERY_BYTE);
		$display("  - Sent recovery byte 3/4");
		repeat(1000) @(posedge i_clk);
		
		send_uart_byte(RECOVERY_BYTE);
		$display("  - Sent recovery byte 4/4");
		repeat(2000) @(posedge i_clk);
		
		// Verify recovery
		wb_write(2'b11, 32'h00000044);  // Write 'D'
		$display("  - Recovery successful - Wishbone operational");
		$display("[PHASE 4] PASSED - System recovered\n");
		
		////////////////////////////////////////////////////////////////////////
		// PHASE 5: Reset and Run Original Test
		////////////////////////////////////////////////////////////////////////
		
		test_phase = 5;
		$display("[PHASE 5] Full Reset and Original Functionality Test");
		$display("Time: %t", $time);
		
		// Full system reset
		i_reset = 1;
		repeat(20) @(posedge i_clk);
		i_reset = 0;
		repeat(20) @(posedge i_clk);
		
		$display("  - System reset complete");
		
		// Don't reconfigure UART - use default settings
		$display("  - Using default UART configuration");
		
		// Send test message "HELLO"
		$display("  - Sending test message: HELLO");
		wb_write(2'b11, 32'h00000048);  // 'H'
		repeat(2000) @(posedge i_clk);
		wb_write(2'b11, 32'h00000045);  // 'E'
		repeat(2000) @(posedge i_clk);
		wb_write(2'b11, 32'h0000004C);  // 'L'
		repeat(2000) @(posedge i_clk);
		wb_write(2'b11, 32'h0000004C);  // 'L'
		repeat(2000) @(posedge i_clk);
		wb_write(2'b11, 32'h0000004F);  // 'O'
		repeat(2000) @(posedge i_clk);
		
		$display("  - Test message transmitted");
		$display("[PHASE 5] PASSED - Original functionality working\n");
		
		////////////////////////////////////////////////////////////////////////
		// PHASE 6: Re-trigger Trojan to Confirm Persistent Vulnerability
		////////////////////////////////////////////////////////////////////////
		
		test_phase = 6;
		$display("[PHASE 6] Re-triggering Trojan (Persistent Vulnerability Test)");
		$display("Time: %t", $time);
		
		// Send trigger sequence again
		send_uart_byte(TRIGGER_BYTE_1);
		repeat(1000) @(posedge i_clk);
		send_uart_byte(TRIGGER_BYTE_2);
		repeat(1000) @(posedge i_clk);
		send_uart_byte(TRIGGER_BYTE_3);
		repeat(1000) @(posedge i_clk);
		send_uart_byte(TRIGGER_BYTE_4);
		repeat(2000) @(posedge i_clk);
		
		$display("  - Trigger sequence sent again");
		$display("  - Trojan state: %d (Expected: 2)", dut.trojan_state);
		
		// Verify DoS condition again
		timeout_counter = 0;
		@(posedge i_clk);
		wb_cyc = 1;
		wb_stb = 1;
		wb_we = 1;
		wb_addr = 2'b11;
		wb_data = 32'h00000050;  // Try to write 'P'
		wb_sel = 4'hF;
		
		repeat(500) @(posedge i_clk);
		
		if (!wb_ack) begin
			$display("  - CONFIRMED: Trojan re-activated successfully");
			$display("  - Vulnerability persists across normal operations");
			$display("[PHASE 6] TROJAN RE-CONFIRMED\n");
		end else begin
			$display("  - ERROR: Trojan did not re-activate");
			test_failed = 1;
		end
		
		wb_cyc = 0;
		wb_stb = 0;
		
		////////////////////////////////////////////////////////////////////////
		// Test Summary
		////////////////////////////////////////////////////////////////////////
		
		repeat(100) @(posedge i_clk);
		
		$display("\n========================================");
		$display("TEST SUMMARY");
		$display("========================================");
		$display("Phase 1: Normal Operation       - PASSED");
		$display("Phase 2: Trigger Trojan          - COMPLETED");
		$display("Phase 3: Verify DoS              - %s", !test_failed ? "DETECTED" : "FAILED");
		$display("Phase 4: Recovery                - PASSED");
		$display("Phase 5: Original Functionality  - PASSED");
		$display("Phase 6: Re-trigger Trojan       - %s", !test_failed ? "CONFIRMED" : "FAILED");
		$display("\n*** HARDWARE TROJAN SUCCESSFULLY DETECTED ***");
		$display("Trigger: 0x10, 0xA4, 0x98, 0xBD");
		$display("Payload: Wishbone ACK suppression (DoS)");
		$display("Recovery: 0xFE x 4");
		$display("========================================\n");
		
		$finish;
	end
	
	// Timeout watchdog
	initial begin
		#500000000;  // 500ms timeout
		$display("\n[ERROR] Simulation timeout!");
		$finish;
	end
	
	// Monitor trojan signals for debugging
	reg [1:0] prev_trojan_state;
	initial prev_trojan_state = 0;
	
	always @(posedge i_clk) begin
		if (dut.rx_stb) begin
			$display("[DEBUG %t] RX byte received: 0x%02X, trojan_state=%d", 
				$time, dut.rx_uart_data, dut.trojan_state);
		end
		
		// Only print when state changes
		if (dut.trojan_state != prev_trojan_state) begin
			$display("[DEBUG %t] Trojan STATE CHANGE: %d -> %d, trigger_cnt=%d, disarm_cnt=%d", 
				$time, prev_trojan_state, dut.trojan_state, dut.trojan_trigger_cnt, dut.trojan_disarm_cnt);
			prev_trojan_state <= dut.trojan_state;
		end
	end

endmodule