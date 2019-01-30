


//`define DISABLE_ADD

`ifndef EQUAL_COMPERATOR
//`define EQUAL_COMPERATOR EqualParAdd
`define EQUAL_COMPERATOR EqualInfere
`endif

module RegisterSet(
    input clk, 
    input we,
    input [5:0] wa,
    input [31:0] wd,
    input [5:0] ra1,
    input [5:0] ra2,
    output reg [31:0] rd1,
    output reg [31:0] rd2
);
    reg [31:0] regs [0:63];

    initial begin
        regs[0] <= 0;
        regs[32] <= 0; // placeholder for unknown CSR
    end

    always @(posedge clk) begin
        if (we) regs[wa] <= wd;
        rd1 <= regs[ra1];
        rd2 <= regs[ra2];
    end
endmodule







module Pipeline #(
    parameter [31:0] START_PC = 0
) (
    input  clk,
    input  rstn,

    output mem_wren,
    output [3:0] mem_wmask,
    output [31:0] mem_wdata,
    output [31:0] mem_addr,
    input [31:0] mem_rdata
);
    localparam integer WORD_WIDTH = 32;

    localparam integer REG_CSR_NONE     = 6'b100000; // used for any unknown CSR
    localparam integer REG_CSR_MTVEC    = 6'b100001;
    localparam integer REG_CSR_MSCRATCH = 6'b100100;
    localparam integer REG_CSR_MEPC     = 6'b100101;
    localparam integer REG_CSR_MCAUSE   = 6'b100110;
    localparam integer REG_CSR_MTVAL    = 6'b100111;

    localparam integer CSR_COUNTER_MCYCLE       = 4'b0010;
    localparam integer CSR_COUNTER_MCYCLEH      = 4'b0011;
    localparam integer CSR_COUNTER_CYCLE        = 4'b0010;
    localparam integer CSR_COUNTER_CYCLEH       = 4'b0011;
    localparam integer CSR_COUNTER_TIME         = 4'b0010;
    localparam integer CSR_COUNTER_TIMEH        = 4'b0011;
    localparam integer CSR_COUNTER_INSTRET      = 4'b0100;
    localparam integer CSR_COUNTER_INSTRETH     = 4'b0101;
    localparam integer CSR_FROM_REGSET          = 4'b1000;


// ---------------------------------------------------------------------
// real registers
// ---------------------------------------------------------------------


    // fetch
    reg [WORD_WIDTH-1:0] f_PC;
    reg f_ChangeInsn;

    // decode
    reg [31:0] d_Insn;
    reg [5:0] d_RdNo1;
    reg [5:0] d_RdNo2;

    reg [31:0] d_DelayedInsn;
    reg d_SaveFetch;
    reg d_Bubble;


    // execute
    reg e_InsnJALR;
    reg e_InsnBEQ;
    reg e_InsnBLTorBLTU;
    reg e_InvertBranch;
    reg [1:0] e_SelLogic;
    reg e_EnShift;
    reg e_ShiftArith;
    reg e_ReturnPC;
    reg e_ReturnUI;
    reg e_LUIorAUIPC;
    reg e_UncondJump;
    reg e_SelJumpTarget;

    reg e_SetCond;
    reg e_LTU;
    reg e_SelSum;
    reg e_MemAccess;
    reg e_MemWr;
    reg [1:0] e_MemWidth;
    reg [3:0] e_CsrCounter;


    reg [WORD_WIDTH-1:0] d_PC;

    reg [WORD_WIDTH-1:0] e_A;
    reg [WORD_WIDTH-1:0] e_B;
    reg [WORD_WIDTH-1:0] e_Imm;
    reg [WORD_WIDTH-1:0] e_PCImm;
    reg [WORD_WIDTH-1:0] e_Target;


    reg e_Carry;
    reg e_WrEn;
    reg [5:0] e_WrNo;
    reg w_Kill;

    // mem stage
    reg m_Kill; // to decode and execute stage
    reg m_WrEn;
    reg [5:0] m_WrNo;
    reg [WORD_WIDTH-1:0] m_WrData;
    reg [6:0] m_MemByte;
    reg [7:0] m_MemSign;
    reg [3:0] m_CsrCounter;

    // write back
    reg w_WrEn;
    reg [5:0] w_WrNo;
    reg [WORD_WIDTH-1:0] w_WrData;


    // exceptions
    reg d_ExcBranch;
    reg e_ExceptionDecode;
    reg e_ExcJAL;
    reg e_ExcIfBranchTaken;
    reg m_ExcIfBranchTaken;
    reg [3:0] e_Cause;
    reg [3:0] m_Cause;
    reg [3:0] w_Cause;
    reg [WORD_WIDTH-1:0] e_MEPC;
    reg [WORD_WIDTH-1:0] m_MEPC;
    reg [WORD_WIDTH-1:0] w_MEPC;
    reg [WORD_WIDTH-1:0] m_MEPCorMTVAL;
    reg m_WriteMTVAL;
    reg m_ThrowException;
    reg w_ThrowException;



    // CSR
    reg        e_CarryCYCLE;
    reg [32:0] e_CounterCYCLE;
    reg [31:0] e_CounterCYCLEH;
    reg        e_CarryINSTRET;
    reg [32:0] e_CounterINSTRET;
    reg [31:0] e_CounterINSTRETH;

    reg [1:0] e_CsrOp;
    reg [1:0] m_CsrOp;
    reg [4:0] e_CsrImm;
    reg [WORD_WIDTH-1:0] m_CsrUpdate;
    reg [5:0] e_CsrWrNo;
    reg [5:0] m_CsrWrNo;

    reg  e_InsnBit14;
    wire e_ShiftRight      = e_InsnBit14;
    wire e_MemUnsignedLoad = e_InsnBit14;
    wire e_CsrSelImm       = e_InsnBit14;



// ---------------------------------------------------------------------
// combinational circuits
// ---------------------------------------------------------------------


    // decode


    wire [WORD_WIDTH-1:0] ImmI = {{21{d_Insn[31]}}, d_Insn[30:20]};


    //                               31|30..12|11..5 | 4..0
    // ImmI for JALR  (opcode 11011) 31|  31  |31..25|24..20
    // ImmI for load  (opcode 00000) 31|  31  |31..25|24..20
    // ImmS for store (opcode 01000) 31|  31  |31..25|11..7
    // ImmU for LUI   (opcode 01101) 31|30..12|   -  |   -
    // 
    // Optimisation: For LUI the lowest 12 bits must not be set correctly to 0,
    // since ReturnImm clears them in the ALU.
    // In fact, this should reduce LUT-size and not harm clock rate, but it does.
    // TRY: check later in more complex design
    wire [WORD_WIDTH-1:0] ImmISU = { // 31 LE
        d_Insn[31],                                                     // 31
        d_Insn[4] ? d_Insn[30:12] : {19{d_Insn[31]}},                   // 30..12
        //d_Insn[31:25],                                                  // 11..5
        //d_Insn[6:5]==2'b01 ? d_Insn[11:7] : d_Insn[24:20])};            // 4..0
        d_Insn[4] ? 7'b0000000 : d_Insn[31:25],                         // 11..5
        d_Insn[4] ? 5'b0 : (d_Insn[6:5]==2'b01 ? d_Insn[11:7] : d_Insn[24:20])}; // 4..0

    //                                31|30..20|19..12|11|10..5 | 4..1 |0
    // ImmB for branch (opcode 11000) 31|  31  |  31  | 7|30..25|11..8 |-
    // ImmJ for JAL    (opcode 11011) 31|  31  |19..12|20|30..25|24..21|-
    // ImmU for AUIPC  (opcode 00101) 31|30..20|19..12| -|   -  |   -  |-
    wire [WORD_WIDTH-1:0] ImmBJU = { // 30 LE
        d_Insn[31],                                                     // 31
        d_Insn[4] ? d_Insn[30:20] : {11{d_Insn[31]}},                   // 30..20
        d_Insn[2] ? d_Insn[19:12] : {8{d_Insn[31]}},                    // 19..12
        ~d_Insn[4] & (d_Insn[2] ? d_Insn[20] : d_Insn[7]),              // 11
        d_Insn[4] ? 6'b000000 : d_Insn[30:25],                          // 10..5
        {4{~d_Insn[4]}} & (d_Insn[2] ? d_Insn[24:21] : d_Insn[11:8]),   // 4..1
        1'b0};                                                          // 0

    wire [WORD_WIDTH-1:0] PCImm = d_PC + ImmBJU;
    wire [WORD_WIDTH-1:0] Target = (d_Insn[6:2]==5'b00011) ? f_PC : PCImm;
        // change for FENCE.I





// 30 14 13 12 6 5 4 3 2 Ki MB
//             1 1 0 0 1  0  0  InsnJALR
//     0  0    1 1 0 0 0  0  0  InsnBEQ
//     1       1 1 0 0 0  0  0  InsnBLTorBLTU
//     1  1    1 1 0 0 0  0  0  InsnBLTU
//             1 1 0 1 1  0  0  (JAL)          \
//           1 1 1 0 0 0  0  0  (BNE,BGE,BGEU)  InvertBranch
//             0 0 0 1 1  0  0  (FENCE.I)      /
//             1 1 0   1        ReturnPC = InsnJALorJALR 
//             0 1 1 0 1        ReturnImm = InsnLUI
//             0 0 1 0 1        ReturnPCImm = InsnAUIPC

//     0  0  1 0   1 0 0        InsnSLL
//  0  1  0  1 0   1 0 0        InsnSRL
//  1  1  0  1 0   1 0 0        InsnSRA
//     0  0  0 0   1 0 0        SelSum = InsnADDorSUB
//             0 0 1 0 0        SelImm

//     1  0  0 0   1 0 0        SelLogic
//     1  0  1 0   1 0 0
//     1  1  0 0   1 0 0
//     1  1  1 0   1 0 0

//             0   1 0 0
//             0   1 0 0

//             1 1 0 0 0        branch \
//     0  0  1 0   1 0 0        SLL     \
//     0  1  0 0   1 0 0        SLT      NegB
//     0  1  1 0   1 0 0        SLTU    /
//  1  0  0    0 1 1 0 0        SUB    /




    // LUT4 at level 1

    wire LTU = d_Insn[6] ? d_Insn[13] : d_Insn[12];
        // select unsigned or signed comparison
        //     funct3 opcode  LTU
        // BLT    100 1100011  0
        // BGE    101 1100011  0
        // BLTU   110 1100011  1
        // BGE    111 1100011  1
        // SLTI   010 0010011  0
        // SLTIU  011 0010011  1
        // SLTI   010 0110011  0
        // SLTIU  011 0110011  1
        //         ^^ ^
        // for all other opcodes, LTU does not mind

    wire ShiftArith     = d_Insn[30];

    wire BranchOpcode   = (d_Insn[6:3]==4'b1100);
    wire BEQOpcode      = ~d_Insn[2] & ~d_Insn[14] & ~d_Insn[13];

    wire UpperOpcode    = ~d_Insn[6] && d_Insn[4:2]==3'b101;
    wire ArithOpcode    = ~d_Insn[6] && d_Insn[4:2]==3'b100;
    wire MemAccess      = ~d_Insn[6] && d_Insn[4:2]==3'b000; // ST or LD
    wire SysOpcode      =  d_Insn[6] && d_Insn[4:2]==3'b100;
    wire PrivOpcode     =  d_Insn[5] && (d_Insn[14:12]==0);
    wire JumpOpcode     =  d_Insn[6:4]==3'b110 && d_Insn[2]; // JAL or JALR
    wire MRETOpcode     = (d_Insn[23:20]==4'b0010);

    wire SUBorSLL       =  d_Insn[13] | d_Insn[12] | (d_Insn[5] & d_Insn[30]);
    wire SUBandSLL      = ~d_Insn[14] & ~d_Insn[6] & d_Insn[4];
    wire PartBranch     = (d_Insn[6:4]==3'b110);
    wire LowPart        = (d_Insn[3:0]==4'b0011);
    wire CsrPart        = (d_Insn[5] & (d_Insn[13] | d_Insn[12]));

    wire vKillOrBubble  = m_Kill | d_Bubble;
    wire vMemOrSys      = (d_Insn[6]==d_Insn[4]) & ~d_Insn[3] & ~d_Insn[2];
        // CAUTION: also true for opcode 1010011 (OP-FP, 32 bit floating point) 

    // LUT4 at level 2

    wire InsnJALR       = BranchOpcode & d_Insn[2];
    wire InsnBEQ        = BranchOpcode & BEQOpcode;
    wire InsnBLTorBLTU  = BranchOpcode & ~d_Insn[2] & d_Insn[14];
    wire InvertBranch   = BranchOpcode & ~d_Insn[2] & d_Insn[12]; // BNE or BGE or BGEU

    wire SelSum         = ArithOpcode & ~d_Insn[14] & ~d_Insn[13] & ~d_Insn[12]; // ADD or SUB
    wire SetCond        = ArithOpcode & ~d_Insn[14] & d_Insn[13]; // SLT or SLTU
    wire SelImm         = ArithOpcode & ~d_Insn[5]; // arith imm, only for forwarding
    wire EnShift        = ArithOpcode & ~d_Insn[13] & d_Insn[12];

    wire MemWr          = MemAccess & d_Insn[5];
    wire [1:0] MemWidth = (MemAccess & ~m_Kill) ? d_Insn[13:12] : 2'b11;  // = no mem access

    wire [1:0] CsrOp    = ((SysOpcode & d_Insn[5]) ? d_Insn[13:12] : 2'b00);
/*
    wire [1:0] CsrOp    = CsrCounter[3]
            ? ((SysOpcode & d_Insn[5]) ? d_Insn[13:12] : 2'b00)
            : 0;
*/




    wire InsnMRET       =  SysOpcode & PrivOpcode & MRETOpcode; // check more bits?

    // OPTIMIZE
    // aligned jal, any branch, fence.i
    wire vInsnFENCEI     = (d_Insn[6:2]==5'b00011);
    wire vInsnJAL       = (d_Insn[6:2]==5'b11011);

    wire vPartJALorBranch = ((d_Insn[3:2]==2'b11) & ~d_Insn[21]) | // aligned JAL
                            (d_Insn[3:2]==2'b00); // any branch
    wire SelJumpTarget  = (PartBranch & vPartJALorBranch) | vInsnFENCEI;
    wire UncondJump     = 
        vInsnJAL |
        vInsnFENCEI |
        ExceptionDecode |
        InsnMRET;


    wire NegB           = ((SUBorSLL & SUBandSLL) | PartBranch) & LowPart;
    wire SaveFetch      = (d_Bubble | (vMemOrSys & ~d_SaveFetch)) & ~m_Kill;
    wire Bubble         = ~m_Kill &
        (vMemOrSys |            // CSR or mem instruction
         MemMisaligned |        // mem exception => second mem bubble
         d_ExcBranch |          // misaligned taken branch
         JumpOpcode);           // JAL or JALR

/*
    wire B2 = 
        ((~d_Bubble & vMemOrSys) |      // CSR or mem instruction
         d_ExcBranch |                  // misaligned taken branch
         JumpOpcode);                   // JAL or JALR
    wire Bubble = ~m_Kill & (B2 |
         (MemMisaligned));              // mem exception => second mem bubble
*/


    // level 1
    wire ArithOrUpper = ~d_Insn[6] & d_Insn[4] & ~d_Insn[3];
    wire DestReg0 = (d_Insn[11:8] == 4'b0000); // x0 as well as unknown CSR (aka x32)
    // level 2
    wire EnableWrite = ArithOrUpper | JumpOpcode | (MemAccess & ~d_Insn[5]);
    wire DisableWrite = (DestReg0 & ~d_Insn[7]) | m_Kill | d_ExcBranch;
    // level 3
    wire DecodeWrEn = ((EnableWrite | (SysOpcode & CsrPart)) & ~DisableWrite);

    wire [5:0] DecodeWrNo = {1'b0, d_Insn[11:7]};



    // control signals for the ALU that are set in the decode stage
//    wire [1:0] SelLogic = (ArithOpcode & d_Insn[14]) ? d_Insn[13:12] : 2'b01;
    wire [1:0] SelLogic = (ArithOpcode & d_Insn[14]) 
        ? d_Insn[13:12] 
        : ((BranchOpcode & BEQOpcode) ? 2'b00 : 2'b01);











    // forwarding

    wire FwdAE = e_WrEn & (d_RdNo1 == e_WrNo); // 4 LE
    wire FwdAM = m_WrEn & (d_RdNo1 == m_WrNo); // 4 LE
    wire FwdAW = w_WrEn & (d_RdNo1 == w_WrNo); // 4 LE
    wire [WORD_WIDTH-1:0] ForwardAR = (FwdAE | FwdAM | FwdAW) ? 0 : RdData1; // 32 LE
    wire [WORD_WIDTH-1:0] ForwardAM = FwdAM ? MemResult : (FwdAW ? w_WrData : 0); // 32 LE
    wire [WORD_WIDTH-1:0] ForwardAE = FwdAE ? ALUResult : (ForwardAR | ForwardAM); // 32 LE

    wire FwdBE = e_WrEn & (d_RdNo2 == e_WrNo) & ~SelImm; // 4 LE
    wire FwdBM = m_WrEn & (d_RdNo2 == m_WrNo) & ~SelImm; // 4 LE
    wire FwdBW = w_WrEn & (d_RdNo2 == w_WrNo); // 4 LE
    wire [WORD_WIDTH-1:0] ForwardImm = SelImm ? ImmI : 0; // 32 LE
    wire [WORD_WIDTH-1:0] ForwardBR = SelImm ?    0 : (FwdBW ? w_WrData : RdData2); // 32 LE
    wire [WORD_WIDTH-1:0] ForwardBM =  FwdBM ? MemResult : (ForwardBR | ForwardImm); // 32 LE
    wire [WORD_WIDTH-1:0] ForwardBE = (FwdBE ? ALUResult : ForwardBM) ^ {WORD_WIDTH{NegB}}; // 32 LE








    // ALU

    wire [WORD_WIDTH-1:0] vLogicResult = ~e_SelLogic[1]
        ? (~e_SelLogic[0] ? (e_A ^ e_B) : 32'h0)
        : (~e_SelLogic[0] ? (e_A | e_B) : (e_A & e_B));
    wire [WORD_WIDTH-1:0] vPCResult =
          (e_ReturnPC ? d_PC : 0);
    wire [WORD_WIDTH-1:0] vUIResult =
        e_ReturnUI ? (e_LUIorAUIPC ? {e_Imm[31:12], 12'b0} : e_PCImm) : 0;

        // Problem if in a csr instruction, rd is equal to rs1:
        // In the second cycle, rs1 is read (as rs2) and a data dependency to rd
        // of the first cycle is recognized, therefore ALUResult is forwarded.
        // ALUResult is not yet the the new value for the CSR, because the
        // correct value is valid not before the mem stage. But this is not the 
        // problem, since the old value of rs1, before writing the CSR value is
        // needed to modify the CSR.
        //
        // Solution:
        // read value of rs1 in first cycle, safe it for one cycle and then
        // use it in the execute stage of the second cycle. Cons:
        //   * additional 32 bit register,
        //   * bitwise logic cannot be combined with normal arithmetic
        //     instruchtions AND, OR due to different operand sources,
        //   * separate logic to select between zimm/rs1,  cannot be
        //     combined with imm/rs2 from arithmetic instructions
        //
        // Alternative solutions:
        //   * recognize special case when rd=rs1 for a csr instruction
        //   * disable forwarding in this case
        //   * ALUResult must be set to rs1 in the first cycle. Then it is
        //     correctly forwarded to the execute stage of the second cycle

    wire vSelSum = e_SelSum & ~w_ThrowException;
    wire vEnableShift = e_EnShift & ~w_ThrowException;

    // OPTIMIZE? vFastResult has one input left
    wire [WORD_WIDTH-1:0] vFastResultPre = vLogicResult | vPCResult | vUIResult;
    wire [WORD_WIDTH-1:0] vFastResult = w_ThrowException ? w_Cause : vFastResultPre;
    wire [WORD_WIDTH-1:0] Sum = e_A + e_B + e_Carry;
    wire [WORD_WIDTH-1:0] vShiftAlternative = {
        vSelSum ? Sum[WORD_WIDTH-1:1] :  vFastResult[WORD_WIDTH-1:1],
        vSelSum ? Sum[0]              : (vFastResult[0] | vCondResultBit)};

    //                         62|61..32|31|30..0
    // SLL (funct3 001)        31|30..1 | 0|  -
    // SRL (funct3 101, i30 0)  -|   -  |31|30..0
    // SRA (funct3 101, i30 1) 31|  31  |31|30..0
    wire [62:0] vShift0 = {
        (e_ShiftRight & ~e_ShiftArith) ? 1'b0 : e_A[31],
        ~e_ShiftRight ? e_A[30:1] : (e_ShiftArith ? {30{e_A[31]}} :  30'b0),
        ~e_ShiftRight ? e_A[0] : e_A[31],
        ~e_ShiftRight ? 31'b0 : e_A[30:0]};

    wire [46:0] vShift1 = e_B[4] ? vShift0[62:16] : vShift0[46:0];
    wire [38:0] vShift2 = e_B[3] ? vShift1[46:8]  : vShift1[38:0];
    wire [34:0] vShift3 = e_B[2] ? vShift2[38:4]  : vShift2[34:0];
    wire [32:0] vShift4 = vEnableShift ? (e_B[1] ? vShift3[34:2]  : vShift3[32:0]) : 0;
    wire [WORD_WIDTH-1:0] ALUResult = (e_B[0] ? vShift4[32:1]  : vShift4[31:0]) | vShiftAlternative;

    wire ExecuteWrEn = w_ThrowException | ((e_WrEn & ~(m_CsrCounter[1] | m_CsrCounter[2])) & ~ExecuteKill);
    wire [5:0] ExecuteWrNo = w_ThrowException ? REG_CSR_MCAUSE : e_WrNo;





    // branch unit


    wire Equal = (vLogicResult == ~0);

    wire vLessXor = e_InvertBranch ^ ((e_A[31] ^ e_LTU) & (e_B[31] ^ e_LTU));
    wire vLessAnd = (e_A[31] ^ e_B[31]);
    wire vUnkilledBEQ = e_InsnBEQ & ~ExecuteKill;


    wire vLess    = ((Sum[31] & vLessAnd) ^ vLessXor);
    wire vUncondJump = e_UncondJump | (e_InsnJALR &  AddrOfs[1]);
    wire vBEQ = vUnkilledBEQ & (e_InvertBranch ^ Equal);

    wire vCondResultBit = e_SetCond & vLess;
    wire vNotBEQ = ((e_InsnBLTorBLTU & vLess) | vUncondJump) & ~ExecuteKill;

    wire vJump = vBEQ | vNotBEQ;
        // taken conditional branch or direct jump or exception

    wire ExecuteKill = m_Kill | w_Kill;
    wire Kill = (vBEQ | vNotBEQ | (e_InsnJALR & ~ExecuteKill));
        // taken conditional branch or direct jump or indirect jump = any jump or exception


    wire [WORD_WIDTH-1:0] AddrSum = e_A + e_Imm;
    wire [WORD_WIDTH-1:0] NextPC = f_PC + 4;
    wire [WORD_WIDTH-1:0] NextOrSum = ((e_MemAccess | e_InsnJALR) & ~ExecuteKill)
        ? {AddrSum[WORD_WIDTH-1:2], 2'b00} : NextPC;
    wire [WORD_WIDTH-1:0] JumpTarget = e_SelJumpTarget ? e_Target : RdData2;
        // TRY: RdData1 instead of RdData2 would also be possible, if vCsrInsn is adjusted
        // FIXME: ForwardBM instead of RdData2 due to data dependencies

    wire [WORD_WIDTH-1:0] MemAddr   = (vBEQ | vNotBEQ)     ? JumpTarget : NextOrSum;
    wire [WORD_WIDTH-1:0] NoBranch  = (d_Bubble & ~e_InsnJALR & ~m_Kill) ? f_PC       : NextOrSum;
    wire [WORD_WIDTH-1:0] FetchPC   = (vBEQ | vNotBEQ)     ? JumpTarget : NoBranch;
    wire [WORD_WIDTH-1:0] DecodePC  = (d_Bubble & ~m_Kill) ? d_PC       : f_PC;








    // memory signals, generated in execute stage


/*
    wire [1:0] AddrOfs = {
        e_A[1] ^ e_Imm[1] ^ (e_A[0] & e_Imm[0]),
        e_A[0] ^ e_Imm[0]};
*/
    wire [1:0] AddrOfs = AddrSum[1:0];

    reg [17:0] MemSignals;
    always @* case ({e_MemWidth, AddrOfs})
        4'b0000: MemSignals = 18'b0_0000001_000001_0001;
        4'b0001: MemSignals = 18'b0_0000010_010010_0010;
        4'b0010: MemSignals = 18'b0_0000100_000100_0100;
        4'b0011: MemSignals = 18'b0_0001000_101000_1000;
        4'b0100: MemSignals = 18'b0_0010001_010000_0011;
        4'b0101: MemSignals = 18'b1_0000000_000000_0000;
        4'b0110: MemSignals = 18'b0_0100100_100000_1100;
        4'b0111: MemSignals = 18'b1_0000000_000000_0000;
        4'b1000: MemSignals = 18'b0_1010001_000000_1111;
        4'b1001: MemSignals = 18'b1_0000000_000000_0000;
        4'b1010: MemSignals = 18'b1_0000000_000000_0000;
        4'b1011: MemSignals = 18'b1_0000000_000000_0000;
        default: MemSignals = 0;
    endcase

    wire MemMisaligned = MemSignals[17];
    wire [6:0] MemByte = MemSignals[16:10];
    wire [5:0] MemSign = e_MemUnsignedLoad ? 0 : MemSignals[9:4];
    wire [3:0] MemWriteMask = MemSignals[3:0];






    // memory stage


    wire SignHH1 = (m_MemSign[5] ? mem_rdata[31] : 1'b0) |                      // 1 LE
                   (m_MemSign[4] ? mem_rdata[15] : 1'b0);
    wire SignHH0 = (m_MemSign[2] ? mem_rdata[23] : 1'b0) |                      // 1 LE
                   (m_MemSign[0] ? mem_rdata[7]  : 1'b0);
    wire [15:0] VectorHH = m_MemByte[6] ? mem_rdata[31:16] : 0;
    wire [15:0] HiHalf = (SignHH1|SignHH0) ? 16'hFFFF : VectorHH | ResultOrMTVAL[31:16];

    wire SignHB1 = (m_MemSign[3] ? mem_rdata[31] : 1'b0) |                      // 1 LE
                   (m_MemSign[1] ? mem_rdata[15] : 1'b0);
    wire [7:0] SelByteHB = (m_MemByte[5] ? mem_rdata[31:24] : 8'b0) |           // 8 LE
                           (m_MemByte[4] ? mem_rdata[15:8]  : 8'b0);
    wire [7:0] HiByte = (SignHH0 | SignHB1) ? 8'hFF : (SelByteHB | ResultOrMTVAL[15:8]);        // 8 LE

    wire [7:0] SelByteLB1 = (m_MemByte[3] ? mem_rdata[31:24] : 8'b0) |          // 8 LE
                            (m_MemByte[2] ? mem_rdata[23:16] : 8'b0);
    wire [7:0] SelByteLB0 = (m_MemByte[1] ? mem_rdata[15:8]  : 8'b0) |          // 8 LE
                            (m_MemByte[0] ? mem_rdata[ 7:0]  : 8'b0);
    wire [7:0] LoByte = SelByteLB1 | SelByteLB0 | ResultOrMTVAL[7:0];

    wire [31:0] MemResult = {HiHalf, HiByte, LoByte};

    wire [WORD_WIDTH-1:0] MemWriteData = {
        e_MemWidth==0 ? e_B[7:0] : (e_MemWidth==1 ? e_B[15:8] : e_B[31:24]),
        (~e_MemWidth[1]) ? e_B[7:0] : e_B[23:16],
        e_MemWidth==0 ? e_B[7:0] : e_B[15:8],
        e_B[7:0]};

    //                                     6         54         3210
    //          31..16  15..8    7..0      HiHalf    HiByte   LoByte    MemByte MemSign
    // lb  00    7..7    7..7    7..0      0 0001    00 0001    0001    0000001 00010001
    // lb  01   15..15  15..15  15..8      0 0010    00 0010    0010    0000010 00100010
    // lb  10   23..23  23..23  23..16     0 0100    00 0100    0100    0000100 01000100
    // lb  11   31..31  31..31  31..24     0 1000    00 1000    1000    0001000 10001000
    // lbu 00     -       -      7..0      0 0000    00 0000    0001    0000001 00000000
    // lbu 01     -       -     15..8      0 0000    00 0000    0010    0000010 00000000
    // lbu 10     -       -     23..16     0 0000    00 0000    0100    0000100 00000000
    // lbu 11     -       -     31..24     0 0000    00 0000    1000    0001000 00000000
    // lh  0.   15..15  15..8    7..0      0 0010    01 0000    0001    0010001 00100000
    // lh  1.   31..31  31..24  23..16     0 1000    10 0000    0100    0100100 10000000
    // lhu 0.     -     15..8    7..0      0 0000    01 0000    0001    0010001 00000000
    // lhu 1.     -     31..24  23..16     0 0000    10 0000    0100    0100100 00000000
    // lw  ..   31..16  15..8    7..0      1 0000    01 0000    0001    1010001 00000000








    // CSRs

    wire Retired = ~d_Bubble & ~m_Kill & ~w_Kill;
        // For the number of retired instructions, do not count bubbles or
        // killed instructions. In the execute stage that can be decided.
    wire [32:0] CounterCYCLE    = {1'b0, e_CounterCYCLE} + 1;
    wire [31:0] CounterCYCLEH   = e_CounterCYCLEH + e_CarryCYCLE;
    wire [32:0] CounterINSTRET  = {1'b0, e_CounterINSTRET} + {62'b0, Retired};
    wire [31:0] CounterINSTRETH = e_CounterINSTRETH + e_CarryINSTRET;

    wire [WORD_WIDTH-1:0] CsrUpdate = e_CsrSelImm ? {27'b0, e_CsrImm} : e_A;






    wire ExcBranch = m_ExcIfBranchTaken & m_Kill;
    wire ReallyWriteMTVAL = m_WriteMTVAL | ExcBranch;

    wire [WORD_WIDTH-1:0] vCsrCYCLE   = m_CsrCounter[1] 
        ? (m_CsrCounter[0] ? e_CounterCYCLEH : e_CounterCYCLE) : 0;
    wire [WORD_WIDTH-1:0] vCsrINSTRET = m_CsrCounter[2] 
        ? (m_CsrCounter[0] ? e_CounterINSTRETH : e_CounterINSTRET) : 0;
    wire [WORD_WIDTH-1:0] vCsrRegSet = ~m_CsrOp[1]
        ? (~m_CsrOp[0] ? 32'h0 : m_CsrUpdate)
        : (~m_CsrOp[0] ? (e_B | m_CsrUpdate) : (e_B & ~m_CsrUpdate));
            // TRY: e_A instead of e_B would also be possible, if vCsrInsn is adjusted

    // e_A is a bypass from the execute stage of the next cycle
    wire [WORD_WIDTH-1:0] vFromALU    = (m_CsrCounter[3:1]==0) ? m_WrData : 0;

    wire [WORD_WIDTH-1:0] vCsrOrALU = vCsrCYCLE | vCsrINSTRET | vCsrRegSet | vFromALU;

    wire [WORD_WIDTH-1:0] ResultOrMTVAL = (w_ThrowException | ReallyWriteMTVAL) ? m_MEPCorMTVAL : vCsrOrALU;

    wire MemWrEn = m_WrEn | w_ThrowException | ReallyWriteMTVAL | (m_CsrCounter[3] && m_CsrWrNo!=0);
    wire [5:0] MemWrNo = 
    m_CsrCounter[3] ? m_CsrWrNo :
    (ReallyWriteMTVAL ? REG_CSR_MTVAL : 
        (w_ThrowException ? REG_CSR_MEPC : m_WrNo));

    assign mem_wren = e_MemWr & ~ExecuteKill;
    assign mem_wmask = MemWriteMask;
    assign mem_wdata = MemWriteData;
    assign mem_addr = MemAddr;






    reg [5:0] vCsrTranslate;
    always @* begin
        case (d_Insn[31:20])
            12'h305: vCsrTranslate <= REG_CSR_MTVEC;
            12'h340: vCsrTranslate <= REG_CSR_MSCRATCH;
            12'h341: vCsrTranslate <= REG_CSR_MEPC;
            12'h342: vCsrTranslate <= REG_CSR_MCAUSE;
            12'h343: vCsrTranslate <= REG_CSR_MTVAL;
            default: vCsrTranslate <= 0; // cannot be written, always 0
        endcase
    end

    reg [3:0] CsrCounter;
    always @* begin
        case (d_Insn[31:20])
            12'hB00: CsrCounter <= CSR_COUNTER_MCYCLE;
            12'hB80: CsrCounter <= CSR_COUNTER_MCYCLEH;
            12'hC00: CsrCounter <= CSR_COUNTER_CYCLE;
            12'hC01: CsrCounter <= CSR_COUNTER_TIME;
            12'hC02: CsrCounter <= CSR_COUNTER_INSTRET;
            12'hC80: CsrCounter <= CSR_COUNTER_CYCLEH;
            12'hC81: CsrCounter <= CSR_COUNTER_TIMEH;
            12'hC82: CsrCounter <= CSR_COUNTER_INSTRETH;
            default: CsrCounter <= CSR_FROM_REGSET;
        endcase
    end


    wire [3:0] Cause = 
        d_ExcBranch ? 0 : (     // B*       instruction address misaligned
            d_Bubble 
                ? (e_MemWr 
                    ? 6         // SW       store address misaligned
                    : 4)        // LW       load address misaligned
                : (d_Insn[4] 
                    ? (d_Insn[20] 
                        ? 3     // EBREAK   breakpoint
                        : 11)   // ECALL    environment call from M-mode
                    : 0));      // JAL,JALR instruction address misaligned

    wire vFirstCsrCycle =  SysOpcode & CsrPart & ~vKillOrBubble & ~d_ExcBranch;
        // set only in the first of the two csr instruction cycles

    wire [31:0] vCsrInsn =
        {7'b0000000,
         vFirstCsrCycle ? vCsrTranslate[4:0] : (InsnMRET ? REG_CSR_MEPC[4:0] : REG_CSR_MTVEC[4:0]),
                        // rs2
         5'b00000,      // rs1=x0
         3'b110,        // func3=OR
         vFirstCsrCycle ? d_Insn[11:7]       : 5'b0,
                        // rd
         7'b0110011};   // opcode=RR



    // In the case of a misaligned memory access, throw the exception in the mem
    // stage of the bubble instruction, but write MTVAL in the mem stage of the
    // actual instruction (one cycle earlier). Therefore ThrowException depends
    // on the registered signal e_ExceptionDecode, while WriteMTVAL
    // depends on the unregistered signal (MemMisaligned & vUnkilledMemAccess).

    wire vExc = e_ExcJAL | (e_InsnJALR & AddrOfs[1]);
    wire ThrowException = (e_ExceptionDecode | vExc) & ~ExecuteKill;
        // true if there really is an exception (in mem stage)
    wire WriteMTVAL = (MemMisaligned | vExc) & ~ExecuteKill;
        // true for exceptions that set MTVAL (in mem stage)

    wire ExcJAL = (d_Insn[6:2]==5'b11011) & d_Insn[21];
        // JAL with unaligned target address

    wire ExceptionDecode =
        (SysOpcode & PrivOpcode & ~d_Insn[22] & ~d_Insn[21]) |
            // throw in decode: EBREAK or ECALL
        MemMisaligned |
            // throw in execute: memory access misaligned
            // forward to decode stage of following instruction bubble
        d_ExcBranch;
            // throw in memory: taken branch to misaligned address

    wire InsnAuxRdNo2H = Bubble;

    wire [31:0] Insn = Bubble ? vCsrInsn : (
        ((d_Bubble | d_SaveFetch) & ~m_Kill) ? d_DelayedInsn : mem_rdata);











// ---------------------------------------------------------------------
// sequential logic
// ---------------------------------------------------------------------



    wire [5:0] RdNo1 = {1'b0, Insn[19:15]};
    wire [5:0] RdNo2 = {InsnAuxRdNo2H, Insn[24:20]};
    wire [WORD_WIDTH-1:0] RdData1;
    wire [WORD_WIDTH-1:0] RdData2;

    RegisterSet RegSet(
        .clk(clk),
        .we(MemWrEn),
        .wa(MemWrNo),
        .wd(MemResult),
        .ra1(RdNo1),
        .ra2(RdNo2),
        .rd1(RdData1),
        .rd2(RdData2)
    );

    always @(posedge clk) begin
        if (!rstn) begin
            e_WrEn <= 0;
            e_MemAccess <= 0;
            e_MemWr <= 0;
            e_MemWidth <= 2'b11; // remove?
            f_PC <= 32'h80000000;

            d_Insn <= 32'h13;
            d_SaveFetch <= 0;
            d_Bubble <= 0;
            d_DelayedInsn <= 0;

            e_CarryCYCLE <= 0;
            e_CounterCYCLE <= 0;
            e_CounterCYCLEH <= 0;
            e_CarryINSTRET <= 0;
            e_CounterINSTRET <= 0;
            e_CounterINSTRETH <= 0;
            e_CsrCounter <= 0;
            m_CsrCounter <= 0;

            // fake a jump to address 0 on reset
            e_ExceptionDecode <= 0;
            e_ExcJAL <= 0;
            e_InsnJALR <= 0;
            e_InsnBEQ <= 0;
            e_InsnBLTorBLTU <= 0;
            e_InvertBranch <= 0;
            e_SelJumpTarget <= 1;
            m_Kill <= 0;
            w_Kill <= 0;
            e_PCImm <= 0;
            e_Target <= START_PC;

            m_WrEn <= 0;
            w_WrEn <= 0;
            m_WriteMTVAL <= 0;
            m_ThrowException <= 0;
            w_ThrowException <= 0;

            d_ExcBranch <= 0;
            e_ExcIfBranchTaken <= 0;
            m_ExcIfBranchTaken <= 0;
            e_UncondJump  <= 1;
        end else begin

            // fetch
            d_Insn <= Insn;
            d_RdNo1 <= RdNo1;
            d_RdNo2 <= RdNo2;
            if (SaveFetch) d_DelayedInsn <= mem_rdata;
            d_SaveFetch <= SaveFetch;
            d_Bubble <= Bubble;


        // decode
        d_PC <= DecodePC;
        e_A <= ForwardAE;
        e_B <= ForwardBE;
        e_Imm <= ImmISU;
        e_PCImm <= PCImm;
        e_Target <= Target;
        e_SelJumpTarget <= SelJumpTarget;


        e_WrEn <= DecodeWrEn;
        e_InsnJALR <= InsnJALR;
        e_InsnBEQ <= InsnBEQ;
        e_InsnBLTorBLTU <= InsnBLTorBLTU;

        e_EnShift <= EnShift;
        e_ShiftArith <= ShiftArith;
        e_ReturnPC <= JumpOpcode;
        e_ReturnUI <= UpperOpcode;
        e_LUIorAUIPC <= d_Insn[5];

        e_SelSum <= SelSum;
        e_SetCond <= SetCond;
        e_LTU <= LTU;
        e_MemAccess <= MemAccess;
        e_MemWr <= MemWr;
        e_MemWidth <= MemWidth;

        e_SelLogic <= SelLogic;
        e_Carry <= NegB;

        e_WrNo <= DecodeWrNo;
        e_InvertBranch <= InvertBranch;
        w_Kill <= m_Kill; 
            // don't kill in execute stage if it is an exception that sets MCAUSE

            e_InsnBit14 <= d_Insn[14];

        // execute
        m_WrEn <= ExecuteWrEn;
        m_WrNo <= ExecuteWrNo;
        m_WrData <= ALUResult;
        m_Kill <= Kill;
        m_MemSign <= MemSign;
        m_MemByte <= MemByte;
        f_PC <= FetchPC;


        // mem stage
        w_WrEn <= MemWrEn;
        w_WrNo <= MemWrNo;
        w_WrData <= MemResult;


            // exception handling
            e_MEPC <= d_ExcBranch 
                ? w_MEPC
                : (d_Bubble ? e_MEPC : d_PC);
            m_MEPC <= e_MEPC;
            w_MEPC <= m_MEPC;

            // CSR write (in memory stage)
            m_MEPCorMTVAL <= m_ThrowException 
                ? m_MEPC 
                : ((e_ExcJAL | e_ExcIfBranchTaken) // TRY: e_MemAcces | e_InsnJALR
                    ? e_PCImm
                    : {AddrSum[WORD_WIDTH-1:1], AddrSum[0] & ~e_InsnJALR}); // TRY: AddrOfs[0]


            e_ExceptionDecode   <= ExceptionDecode;
            e_ExcJAL            <= ExcJAL;

            // exception on unconditional branch
            e_ExcIfBranchTaken  <= (d_Insn[6:2]==5'b11000) & d_Insn[8];
                // detect a branch with unaligned offset in decode stage
            m_ExcIfBranchTaken  <= e_ExcIfBranchTaken & ~ExecuteKill;
                // kill on request in execute stage
            d_ExcBranch         <= ExcBranch;
                // throw in mem stage if branch was taken in execute stage

            // potential exception cause (only one possible per instruction class)
            e_Cause             <= Cause;
            m_Cause             <= e_Cause;
            w_Cause             <= m_Cause;
            m_WriteMTVAL        <= WriteMTVAL;
            m_ThrowException    <= ThrowException;
            w_ThrowException    <= m_ThrowException;
            e_UncondJump        <= UncondJump;

            // CSR decode
            e_CarryCYCLE        <= CounterCYCLE[32];
            e_CounterCYCLE      <= CounterCYCLE[31:0];
            e_CounterCYCLEH     <= CounterCYCLEH;
            e_CarryINSTRET      <= CounterINSTRET[32];
            e_CounterINSTRET    <= CounterINSTRET[31:0];
            e_CounterINSTRETH   <= CounterINSTRETH;

            e_CsrImm            <= d_Insn[19:15];
            m_CsrUpdate         <= CsrUpdate;

//            e_CsrOp             <= CsrCounter[3] ? CsrOp : 0;
            e_CsrOp             <= CsrOp;
            e_CsrCounter        <= (CsrOp==0) ? 0 : CsrCounter;
            e_CsrWrNo           <= vCsrTranslate;
            m_CsrOp             <= e_CsrOp;
            m_CsrCounter        <= (w_Kill || m_Kill) ? 0 : e_CsrCounter;
            m_CsrWrNo           <= e_CsrWrNo;





`ifdef DEBUG
        $display("F wren=%b wmask=%b wdata=%h addr=%h rdata=%h",
            mem_wren, mem_wmask, mem_wdata, mem_addr, mem_rdata);
        $display("D pc=\033[1;33m%h\033[0m PC%h d_Insn=%h Insn=%h",
            d_PC, d_PC, d_Insn, Insn);
        $display("R  0 %h %h %h %h %h %h %h %h", 
            RegSet.regs[0], RegSet.regs[1], RegSet.regs[2], RegSet.regs[3], 
            RegSet.regs[4], RegSet.regs[5], RegSet.regs[6], RegSet.regs[7]);
        $display("R  8 %h %h %h %h %h %h %h %h", 
            RegSet.regs[8], RegSet.regs[9], RegSet.regs[10], RegSet.regs[11], 
            RegSet.regs[12], RegSet.regs[13], RegSet.regs[14], RegSet.regs[15]);
        $display("R 16 %h %h %h %h %h %h %h %h", 
            RegSet.regs[16], RegSet.regs[17], RegSet.regs[18], RegSet.regs[19], 
            RegSet.regs[20], RegSet.regs[21], RegSet.regs[22], RegSet.regs[23]);
        $display("R 24 %h %h %h %h %h %h %h %h", 
            RegSet.regs[24], RegSet.regs[25], RegSet.regs[26], RegSet.regs[27], 
            RegSet.regs[28], RegSet.regs[29], RegSet.regs[30], RegSet.regs[31]);

        $display("D read x%d=%h x%d=%h", 
            d_RdNo1, RdData1, d_RdNo2, RdData2);

        $display("D Bubble=%b SaveFetch=%b",
            d_Bubble, d_SaveFetch);
        $display("Y InsnJALR=%b InsnMRET=%b vFirstCsrCycle=%b vCsrInsn=%h d_DelayedInsn=%h",
            InsnJALR, InsnMRET, vFirstCsrCycle, vCsrInsn, d_DelayedInsn);
//        $display("Y Bubble=%b SaveFetch=%b ExceptionDecode=%b MemMisaligned=%b d_ExcBranch=%b",
//            Bubble, SaveFetch, ExceptionDecode, MemMisaligned, d_ExcBranch);


        $display("E a=%h b=%h -> %h",
            e_A, e_B, ALUResult);


        if (vJump || e_InsnJALR) $display("B jump %h", FetchPC);


        $display("F AE=%b AM=%b AW=%b AR=%h AM=%h AE=%h",
            FwdAE, FwdAM, FwdAW, ForwardAR, ForwardAM, ForwardAE);
        $display("F BE=%b BM=%b BW=%b BR=%h BM=%h BE=%h SelImm=%b",
            FwdBE, FwdBM, FwdBW, ForwardBR, ForwardBM, ForwardBE, SelImm);


        $display("C MTVEC=%h MSCRATCH=%h MEPC=%h",
            RegSet.regs[REG_CSR_MTVEC],
            RegSet.regs[REG_CSR_MSCRATCH],
            RegSet.regs[REG_CSR_MEPC]);
        $display("C MCAUSE=%h MTVAL=%h",
            RegSet.regs[REG_CSR_MCAUSE],
            RegSet.regs[REG_CSR_MTVAL]);
/*
        $display("C m_MEPC=%h vFastResult=%h vNotSh=%h m_ThrowE=%b",
            m_MEPC, vFastResult, vNotShiftResult, m_ThrowException);
        $display("C vLogicResult=%h vPCResult=%h vImmOrCsrResult=%h vCsrResult=%h e_CsrOp=%b",
            vLogicResult, vPCResult, vImmOrCsrResult, vCsrResult, e_CsrOp);
        $display("C vOverwriteByCsrRead=%h m_CsrOp=%b ResultOrMTVAL=%h",
            vOverwriteByCsrRead, m_CsrOp, ResultOrMTVAL);
*/
        $display("Z e_SelJumpTarget=%b JumpTarget=%h NextOrSum=%h NoBranch=%h",
            e_SelJumpTarget, JumpTarget, NextOrSum, NoBranch);
        $display("Z Target=%h e_Target=%h",
            Target, e_Target);




//        $display("C w_Kill=%b m_Kill=%b m_ThrowException=%b", 
//            w_Kill, m_Kill, m_ThrowException); 

        $display("C vCsrTranslate=%h InsnAuxRdNo1H=%b CsrOp=%b m_CsrCounter=%b",
            vCsrTranslate, InsnAuxRdNo1H, CsrOp, m_CsrCounter);
        $display("C vCsrOrALU=%h ResultOrMTVAL=%h",
            vCsrOrALU, ResultOrMTVAL);
        $display("M MemResult=%h m_MemSign=%b m_MemByte=%b",
            MemResult, m_MemSign, m_MemByte);

        $display("X d_ExcBranch=%b ExcBranch=%b m_ExcIfBranchTaken=%b m_MEPCorMTVAL=%h",
            d_ExcBranch, ExcBranch, m_ExcIfBranchTaken, m_MEPCorMTVAL);
        $display("X e_ExceptionDecode=%b ExceptionDecode=%b m_Kill=%b w_Kill=%b",
            e_ExceptionDecode, ExceptionDecode, m_Kill, w_Kill);
        $display("X e_MemWidth=%b AddrOfs=%b MemMisaligned=%b",
            e_MemWidth, AddrOfs, MemMisaligned);



//        if (e_WrEn) $display("E x%d", e_WrNo);
        if (m_WrEn) $display("M x%d<-%h", m_WrNo, m_WrData);
        if (w_WrEn) $display("W x%d<-%h",w_WrNo, w_WrData);
`endif


        end
    end

endmodule
