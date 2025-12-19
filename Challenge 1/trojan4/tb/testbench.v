`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	tb_payload_test.v
//
// Purpose: 	Testbench to confirm the trojan's PAYLOAD (bit-reversal).
//
// 				This testbench assumes 'ufifo_fixed.v' is being used.
//
//				1. Resets the DUT (with the long wait for sync).
//				2. Configures the DUT via Wishbone.
//				3. Tests normal operation (sends 0x55, reads 0x55).
//				4. Sends the 3x 0xAF activation sequence.
//				5. Flushes the 3x 0xAF bytes from the (now working) FIFO.
//				6. Tests payload (sends 0x55, expects to read 0xAA).
//				7. Tests payload (sends 0x41, expects to read 0x82).
//
////////////////////////////////////////////////////////////////////////////////

module tb_payload_test;

    // Clock and reset
    reg clk;
    reg reset;
   
    // Wishbone interface
    reg wb_cyc;
    reg wb_stb;
    reg wb_we;
    reg [1:0] wb_addr;
    reg [31:0] wb_data;
    reg [3:0] wb_sel;
    wire wb_stall;
    wire wb_ack;
    wire [31:0] wb_rdata;
   
    // UART signals
    reg i_uart_rx;
    wire o_uart_tx;
    reg i_cts_n;
    wire o_rts_n;
    wire o_uart_rx_int, o_uart_tx_int;
    wire o_uart_rxfifo_int, o_uart_txfifo_int;
   
    // UART parameters
    parameter CLOCK_FREQ = 100_000_000;
    parameter BAUD_RATE = 115200;
    parameter CLOCKS_PER_BAUD = CLOCK_FREQ / BAUD_RATE;
    parameter [30:0] UART_SETUP = CLOCKS_PER_BAUD;
   
    // Test control
    integer test_number;
    integer pass_count;
    integer fail_count;

    // Instantiate the DUT
    wbuart #(
        .INITIAL_SETUP(UART_SETUP),
        .LGFLEN(4),
        .HARDWARE_FLOW_CONTROL_PRESENT(1'b0)
    ) dut (
        .i_clk(clk),
        .i_reset(reset),
        .i_wb_cyc(wb_cyc),
        .i_wb_stb(wb_stb),
        .i_wb_we(wb_we),
        .i_wb_addr(wb_addr),
        .i_wb_data(wb_data),
        .i_wb_sel(wb_sel),
        .o_wb_stall(wb_stall),
        .o_wb_ack(wb_ack),
        .o_wb_data(wb_rdata),
        .i_uart_rx(i_uart_rx),
        .o_uart_tx(o_uart_tx),
        .i_cts_n(i_cts_n),
        .o_rts_n(o_rts_n),
        .o_uart_rx_int(o_uart_rx_int),
        .o_uart_tx_int(o_uart_tx_int),
        .o_uart_rxfifo_int(o_uart_rxfifo_int),
        .o_uart_txfifo_int(o_uart_txfifo_int)
    );

    // Clock generation (100 MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    // Test status display task
    task display_test_status;
        input [255:0] test_name;
        input pass;
        begin
            if (pass) begin
                $display("[PASS] Test %0d: %s", test_number, test_name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] Test %0d: %s", test_number, test_name);
                fail_count = fail_count + 1;
            end
            test_number = test_number + 1;
        end
    endtask

    // Task to send a byte via UART RX
    task send_uart_byte;
        input [7:0] data;
        integer i;
        begin
            // Ensure line is idle before starting
            i_uart_rx = 1'b1;
            repeat(CLOCKS_PER_BAUD * 2) @(posedge clk);
            
            // Start bit
            i_uart_rx = 1'b0;
            repeat(CLOCKS_PER_BAUD) @(posedge clk);
            
            // Data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                i_uart_rx = data[i];
                repeat(CLOCKS_PER_BAUD) @(posedge clk);
            end
            
            // Stop bit
            i_uart_rx = 1'b1;
            repeat(CLOCKS_PER_BAUD) @(posedge clk);
            
            // Extra idle time
            repeat(CLOCKS_PER_BAUD * 2) @(posedge clk);
        end
    endtask

    // Task to check if RX FIFO has data
    task check_rx_fifo_status;
        output has_data;
        reg [31:0] fifo_status;
        begin
            @(posedge clk);
            wb_cyc = 1'b1;
            wb_stb = 1'b1;
            wb_we = 1'b0;
            wb_addr = 2'b01; // UART_FIFO
            wb_sel = 4'hF;
            
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            fifo_status = wb_rdata;
            
            wb_cyc = 1'b0;
            wb_stb = 1'b0;
            @(posedge clk);
            
            // Check bit[0] of lower 16 bits (RX FIFO status)
            has_data = fifo_status[0];
        end
    endtask

    // Task to read from UART via Wishbone (without waiting)
    task read_uart_rxreg_nowait;
        output [31:0] read_data;
        begin
            @(posedge clk);
            wb_cyc = 1'b1;
            wb_stb = 1'b1;
            wb_we = 1'b0;
            wb_addr = 2'b10; // UART_RXREG
            wb_sel = 4'hF;
            
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            read_data = wb_rdata;
            
            @(posedge clk);
            wb_cyc = 1'b0;
            wb_stb = 1'b0;
            @(posedge clk);
        end
    endtask

    // Task to wait for and read one byte
    task wait_and_read_byte;
        output [7:0] byte_data;
        reg [31:0] read_val;
        reg has_data;
        integer timeout;
        begin
            timeout = 0;
            has_data = 0;
            
            // Wait for data to be available
            while (!has_data && timeout < 30000) begin
                check_rx_fifo_status(has_data);
                if (!has_data) begin
                    repeat(10) @(posedge clk);
                    timeout = timeout + 10;
                end
            end
            
            if (timeout >= 30000) begin
                $display("  WARNING: Timeout waiting for RX data (waited %0d clocks)", timeout);
                byte_data = 8'hxx;
            end else begin
                read_uart_rxreg_nowait(read_val);
                byte_data = read_val[7:0];
            end
        end
    endtask

    // Task to write UART setup register
    task write_uart_setup;
        input [30:0] setup_value;
        begin
            @(posedge clk);
            wb_cyc = 1'b1;
            wb_stb = 1'b1;
            wb_we = 1'b1;
            wb_addr = 2'b00; // UART_SETUP
            wb_data = {1'b0, setup_value};
            wb_sel = 4'hF;
            
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            
            @(posedge clk);
            wb_cyc = 1'b0;
            wb_stb = 1'b0;
            @(posedge clk);
        end
    endtask

    // Main test sequence
    initial begin
        // Initialize
        test_number = 1;
        pass_count = 0;
        fail_count = 0;
        
        clk = 0;
        reset = 1;
        wb_cyc = 0;
        wb_stb = 0;
        wb_we = 0;
        wb_addr = 0;
        wb_data = 0;
        wb_sel = 0;
        i_uart_rx = 1'b1; // Idle high
        i_cts_n = 1'b0;   // Clear to send
        
        // Release reset
        repeat(10) @(posedge clk);
        reset = 0;
        
        $display("=====================================================");
        $display("Trojan Payload (Bit-Reversal) Test");
        $display("Using fixed FIFO: ufifo_fixed.v");
        $display("=====================================================");
        
        // Wait for rxuart to get out of reset (this was the bug)
        $display("[INFO] Waiting 15,000 clocks for rxuart line synchronization...");
        repeat(15000) @(posedge clk);
        $display("[INFO] rxuart should now be synchronized.");
        
        // Configure UART
        write_uart_setup(UART_SETUP);
        repeat(10) @(posedge clk);
        
      // Configure UART
        write_uart_setup(UART_SETUP);
        
        // This write RESETS the rxuart. We MUST wait for it to re-synchronize.
        $display("[INFO] Waiting 15,000 clocks for rxuart to re-sync after setup write...");
        repeat(15000) @(posedge clk);
        $display("[INFO] rxuart re-synchronized.");
        
        // -----------------------------------------------------------------
        $display("\n--- PHASE 1: Test Normal Operation ---");
        // -----------------------------------------------------------------
        begin
            reg [7:0] received;
            $display("Sending 0x55...");
            send_uart_byte(8'h55);
            wait_and_read_byte(received);
            $display("Received 0x%02X (Expected 0x55)", received);
            display_test_status("Normal operation (0x55 -> 0x55)", received == 8'h55);
        end

        // -----------------------------------------------------------------
        $display("\n--- PHASE 2: Activate Trojan ---");
        // -----------------------------------------------------------------
        $display("Sending trojan activation sequence: 0xAF, 0xAF, 0xAF");
        send_uart_byte(8'hAF);
        send_uart_byte(8'hAF);
        send_uart_byte(8'hAF);
        
        // We MUST read the 0xAF bytes out to flush the FIFO
        $display("Flushing activation bytes from FIFO...");
        begin
            reg [7:0] dummy;
            wait_and_read_byte(dummy); $display("  Flushed 0x%02X", dummy);
            wait_and_read_byte(dummy); $display("  Flushed 0x%02X", dummy);
            wait_and_read_byte(dummy); $display("  Flushed 0x%02X", dummy);
        end
        $display("Trojan should be active now.");

        // -----------------------------------------------------------------
        $display("\n--- PHASE 3: Test Trojan Payload (Bit-Reversal) ---");
        // -----------------------------------------------------------------
        
        // Test 1: 0x55 (01010101) -> 0xAA (10101010)
        begin
            reg [7:0] received;
            $display("Sending 0x55...");
            send_uart_byte(8'h55);
            wait_and_read_byte(received);
            $display("Received 0x%02X (Expected 0xAA)", received);
            display_test_status("Payload test (0x55 -> 0xAA)", received == 8'hAA);
        end
        
        // Test 2: 0x41 (01000001) -> 0x82 (10000010)
        begin
            reg [7:0] received;
            $display("Sending 0x41 ('A')...");
            send_uart_byte(8'h41);
            wait_and_read_byte(received);
            $display("Received 0x%02X (Expected 0x82)", received);
            display_test_status("Payload test (0x41 -> 0x82)", received == 8'h82);
        end

        // Test 3: 0xF0 (11110000) -> 0x0F (00001111)
        begin
            reg [7:0] received;
            $display("Sending 0xF0...");
            send_uart_byte(8'hF0);
            wait_and_read_byte(received);
            $display("Received 0x%02X (Expected 0x0F)", received);
            display_test_status("Payload test (0xF0 -> 0x0F)", received == 8'h0F);
        end

        // -----------------------------------------------------------------
        $display("\n--- FINAL SUMMARY ---");
        // -----------------------------------------------------------------
        $display("Total Tests: %0d", test_number - 1);
        $display("Passed:      %0d", pass_count);
        $display("Failed:      %0d", fail_count);
        
        if (fail_count == 0)
            $display("\n*** ALL TESTS PASSED! Trojan payload confirmed! ***");
        else
            $display("\n*** TESTS FAILED! Review log. ***");
            
        $display("=====================================================");
        
        repeat(100) @(posedge clk);
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #100_000_000; // 100ms timeout
        $display("ERROR: Simulation timeout!");
        $finish;
    end
   
endmodule