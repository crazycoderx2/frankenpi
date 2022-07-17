module C4(
	input             clk,
	output reg  [7:0] leds,
	
	// FPGA <--> ISA interface
	input       [9:0] A,          // ISA address
	inout  reg  [7:0] D,          // ISA data
	input             IOR,        // ISA IOR
	input             IOW,        // ISA IOW
	input             MEMR,       // ISA MEMR
	input             MEMW,       // ISA MEMW
	output reg  [7:2] IRQ,        // ISA IRQ[7:2]
	output reg        DRQ1,       // ISA DRQ1
	input             DACK1,      // ISA DACK1
	
	// FPGA --> Raspberry Pi data output interface
	output reg  [7:0] GPIO_AD,    // GPIO[7:0]   FPGA --> Raspberry Pi address/data
	output reg  [1:0] REQ,        // GPIO[9:8]   FPGA --> Raspberry Pi request/address/data
	input             ACK,        // GPIO[10]    FPGA <-- Raspberry Pi acknowledge	
	
	// FPGA <-- Raspberry Pi audio data interface
	input       [5:0] GPIO_AUDIO, // GPIO[16:11] FPGA <-- Raspberry Pi audio data in, 6 bits / clock, 18 bit audio data
	output reg        GPIO_ARQ,   // GPIO[17]    FPGA --> Raspberry Pi audio data request
	input             GPIO_ACL,   // GPIO[18]    FPGA <-- Raspberry Pi audio data acknowledge

	// FPGA <-- Raspberry Pi data input interface
	input       [3:0] GPIO_DI,    // GPIO[22:19] FPGA <-- Raspberry Pi data
	input             GPIO_ICL,   // GPIO[24]    FPGA <-- Raspberry Pi clock
	
	output            SPDIF
);

/*
 PINOUT

 A0    7 10 GPIO21  | GND    GND GND GND
 A1   11 28 GPIO19  | (GP26)  NC 137 GPIO20
 A2   30 31 GPIO18  | GPIO13 136 135 GPIO16
 A3   32 33 DRQ1    | GPIO12 133 132 GPIO06
 A4   34 38 DACK1   | GPIO00 129 128 GPIO05
 A5   39 42 CLK     | GPIO07 127 126 GPIO01
 A6   46 49 A9      | GPIO08 125 124 GPIO11
 A7   50 51 A8      | (GP25) 121 120 GPIO09
 ------------------------------------------
 IRQ3 52 53 D7      | GPIO24 119 115 GPIO10
 IRQ4 54 55 D6      | GPIO23 114 111 GPIO22
 IRQ5 58 59 D5      | GPIO15 110 106 GPIO17
 IRQ6 60 64 D4      | GPIO14 105 104 GPIO04
 IRQ7 65 66 D3      | GPIO2  100  85 GPIO03
 IRQ2 67 68 D2      | SPDIF   84  83 (MIDI)
      69 70 D1      | IOR     80  77 IOW
 (AEN)71 72 D0      | MEMR    76  75 MEMW
                    | GND            VCC
*/

reg [24:0] cnt;

reg  [1:0] IOWr;
reg  [1:0] IORr;
reg  [1:0] ACKr;
reg  [1:0] GPIO_ICLr;

wire IOW_falling = (IOWr==2'b10);
wire IOW_rising = (IOWr==2'b01);
wire IOR_falling = (IORr==2'b10);
wire IOR_rising = (IORr==2'b01);
wire ACK_falling = (ACKr==2'b10);
wire ACK_rising = (ACKr==2'b01);
wire GPIO_ICL_rising = (GPIO_ICLr==2'b01);
wire GPIO_ICL_falling = (GPIO_ICLr==2'b10);

reg  [7:0] adlib_detect;
reg  [7:0] adlib_reg;

reg  [5:0] audio_fifo[511:0];
reg  [7:0] wr_audio;
reg  [7:0] rd_audio;

reg  [7:0] out_fifo[255:0];
reg  [7:0] wr_fifo;
reg  [7:0] rd_fifo;

reg  [3:0] in_fifo[1023:0];
reg  [9:0] in_wr_fifo;
reg  [9:0] in_rd_fifo;

always @(posedge clk)
begin
	//if(cnt>32000000) IRQ[7] <= 1;
	//else IRQ[7] <= 0;
	
	cnt <= cnt + 1;
	
	IOWr <= {IOWr[0], IOW};
	IORr <= {IORr[0], IOR};
	ACKr <= {ACKr[0], ACK};
	GPIO_ICLr <= {GPIO_ICLr[0], GPIO_ICL};
	
	// IO write
	if(IOW_rising)
	case(A)
		10'h170: // [hdd] write: reset/read, read: status
		begin
			out_fifo[wr_fifo+0] <= 8'h70;
			out_fifo[wr_fifo+1] <= D;
			wr_fifo <= wr_fifo + 2;
			in_rd_fifo <= 0;
			in_wr_fifo <= 0;
		end
		10'h171: // [hdd] write: chs+data, read: data
		begin
			out_fifo[wr_fifo+0] <= 8'h71;
			out_fifo[wr_fifo+1] <= D;
			wr_fifo <= wr_fifo + 2;
		end
		
		10'h388: // adlib register
		begin
			out_fifo[wr_fifo+0] <= 8'h38;
			out_fifo[wr_fifo+1] <= D;
			wr_fifo <= wr_fifo + 2;
			adlib_detect <= 0;
			adlib_reg <= D;			
		end
		10'h389: // adlib data
		begin
			out_fifo[wr_fifo+0] <= 8'h39;
			out_fifo[wr_fifo+1] <= D;
			wr_fifo <= wr_fifo + 2;
			if(adlib_reg==8'h60 && D==8'h04) adlib_detect <= 8'h00;
			if(adlib_reg==8'h04 && D==8'h21) adlib_detect <= 8'hC0;
		end
	endcase

	// IO read
	if(IOR_falling)
	case(A)
		10'h170: D <= (in_wr_fifo==1023 ? 255 : in_wr_fifo>>3);
		10'h171:
		begin
			D <= {in_fifo[in_rd_fifo+1], in_fifo[in_rd_fifo]};
			in_rd_fifo <= in_rd_fifo + 2;
		end
		10'h22a: D <= 8'haa; // SB detect
		10'h22c: D <= 0;     // SB detect
		10'h22e: D <= 8'hff; // SB detect
		10'h388: D <= adlib_detect;
		default: D <= 8'hZ;
	endcase

	if(IOR_rising)
		D <= 8'hZ;

	// IO output fifo
	if(rd_fifo!=wr_fifo)
	begin
		REQ[0] <= 1;
		if(rd_fifo[0]==0) REQ[1] <= 0;
		if(rd_fifo[0]==1) REQ[1] <= 1;
		GPIO_AD <= out_fifo[rd_fifo];
		if(ACK_rising)
			rd_fifo <= rd_fifo + 1;
	end else
		REQ <= 0;
		
	// IO input fifo
	if(GPIO_ICL_rising)
	begin
		in_fifo[in_wr_fifo] <= GPIO_DI;
		if(in_wr_fifo<1023) in_wr_fifo <= in_wr_fifo + 1;
	end
end

spdif_core spdif_core(
    .clk_i(spdif_clk),
    .rst_i(0),
	 .bit_out_en_i(1),
	 .spdif_o(SPDIF),
	 .sample_i({20'd0, 20'd0})
);

spdif_pll spdif_pll(
	.inclk0(clk),
	.c0(spdif_clk)
	);

endmodule