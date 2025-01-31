////////////////////////////////////////////////////////////////////////////////
// Project Name:	COCO3 Targeting MISTer 
// File Name:		sdc.sv
//
// SD Controller for MISTer
//
////////////////////////////////////////////////////////////////////////////////
//
// Code based partily on work by Gary Becker
// Copyright (c) 2008 Gary Becker (gary_l_becker@yahoo.com)
//
// SD Controller (sdc.vs) by Stan Hodge (stan.pda@gmail.com)
// Copyright (c) 2022 by Stan Hodge (stan.pda@gmail.com)
//
// All rights reserved

// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// Redistributions in synthesized form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of the author nor the names of other contributors may
// be used to endorse or promote products derived from this software without
// specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Please report bugs to the author, but before you do so, please
// make sure that this is not a derivative work and that
// you have the latest version of this file.
//
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

//	Define Config features
`include "../RTL/config.v"

module sdc(
	input        		CLK,     		// clock
	input        		RESET_N,	   	// async reset
	input  		[3:0]	ADDRESS,       	// i/o port addr [extended for coco]
	input  		[7:0]	SDC_DATA_IN,    // data in
	output 		[7:0] 	SDC_READ_DATA, 	// data out

	input				SDC_EN,			// SDC is active
	input				CLK_EN,
	input				SDC_WR,
	input				SDC_RD,

	output	reg			sdc_HALT,

	output	reg			ext_response,
	output	reg			sdc_always,
	
// 	SD block level interface

	output		[31:0] 	sd_lba[2],
	output reg	[1:0]	sd_rd,
	output reg  [1:0]	sd_wr,
	input       [1:0]	sd_ack,

//	Drive descripters

	input				drive_wp[2],
	input		[1:0]	drive_ready,
	input		[31:0]	drive_size[2],


// 	SD byte level access. Signals for 2-PORT altsyncram.
	input  		[8:0]	sd_buff_addr,
	input  		[7:0] 	sd_buff_dout,
	output 		[7:0] 	sd_buff_din[2],
	input        		sd_buff_wr

);

reg		[23:0]	LSN;
reg		[7:0]	command;
reg		[7:0]	transfer_address;

reg				new_cmd, new_cmd_d, cmd_done;
reg 			data_inc, run;
reg				rxt_res_end;
reg				transfer_clear;
reg		[3:0]	sdc_data_reg;

wire	[7:0]	sdc_status_reg = {sdc_data_reg, 4'h4};

enum int unsigned
{
	state_idle = 0,

	state_read = 1,
	state_r1 = 2,
	state_r1a = 3,
	state_r2 = 4,
	state_r3 = 5,
	state_r4 = 6,

	state_write = 7,
	state_w1 = 8,
	state_w1a = 9,
	state_w2 = 10,
	state_w3 = 11,
	state_w4 = 12,

	state_ext = 13,
	state_e1 = 14,
	state_e2 = 15

} state;

localparam ADRS_FF42 =				4'h2;
localparam ADRS_FF43 =				4'h3;
localparam ADRS_FF48 =				4'h8;
localparam ADRS_FF49 =				4'h9;
localparam ADRS_FF4A =				4'hA;
localparam ADRS_FF4B =				4'hB;


always @(negedge CLK or negedge RESET_N)
begin
	if(!RESET_N)
	begin
		LSN <= 24'h000000;
		command <= 8'h00;
		new_cmd <= 1'b0;
		data_inc <=	1'b0;
		rxt_res_end <= 1'b0;
		transfer_address <= 8'h00;
		sdc_data_reg <=	4'h0;
	end
	else
	begin
		data_inc <=	1'b0;
		rxt_res_end <= 1'b0;
		if (cmd_done)
			new_cmd <= 1'b0;

		if (CLK_EN & SDC_WR)													//Write
		begin
			case(ADDRESS)
			ADRS_FF42:						// $ff42
				sdc_data_reg <=	SDC_DATA_IN[7:4];

			endcase
		end

		if (SDC_EN & CLK_EN & SDC_WR)													//Write
		begin
			case(ADDRESS)

			ADRS_FF48:						// $ff48
				begin
					command <= 		SDC_DATA_IN;
					transfer_address <= 8'h00;
					new_cmd <=		1'b1;
				end

			ADRS_FF49:						// $ff49
				if (~run)
					LSN[23:16] <= 	SDC_DATA_IN;
		
			ADRS_FF4A:						// $ff4A
				begin
					if (~run)
						LSN[15:8] <=  	SDC_DATA_IN;
					else
						data_inc <=		1'b1;
				end
			
			ADRS_FF4B:						// $ff4B
				begin
					if (~run)
						LSN[7:0] <=   	SDC_DATA_IN;
					else
					begin
						data_inc <=		1'b1;
					end
				end
			endcase
		end

		if (CLK_EN & SDC_RD & (ADDRESS[3:1] == 3'b101) & (run))		// Read @ $ff4A / $ff4B
			data_inc <=	1'b1;

		if (CLK_EN & SDC_RD & (ADDRESS[3:0] == 4'b1001) & (~run))	// Read @ $ff49 [last of size data]
			rxt_res_end <= 	1'b1;

		if (data_inc)
			transfer_address <= transfer_address + 1'b1;

		if (transfer_clear)
			transfer_address <= 8'h00;

	end
end

wire			sdc_fail, sdc_ready, sdc_busy;

localparam 		CMD_READ  = 			5'b10000;
localparam 		CMD_WRITE = 			5'b10100;
localparam 		CMD_EXT = 				5'b11000;

reg				wr_cmd;
reg				ack_d;
reg		[23:0]	response_reg;
wire			end_ack = ~sd_ack[l_drive] & ack_d;
reg				l_drive, buffer_upper;
reg				time_clr;
reg		[13:0]	delay_time;

always @(negedge CLK or negedge RESET_N)
begin
	if(!RESET_N)
	begin
		state <= state_idle;
		sdc_ready <= 1'b0;
		sdc_busy <= 1'b0;
		sd_rd[0] <= 1'b0;
		sd_rd[1] <= 1'b0;
		sd_wr[0] <= 1'b0;
		sd_wr[1] <= 1'b0;
		sd_lba[0] <= 32'h00000000;
		sd_lba[1] <= 32'h00000000;
		run <= 1'b0;
		cmd_done <= 1'b0;
		wr_cmd <= 1'b0;
		ack_d <= 1'b0;
		transfer_clear <= 1'b0;
		sdc_fail <= 1'b0;
		ext_response <= 1'b0;
		response_reg <= 24'h000000;
		sdc_always <= 1'b0;
		sdc_HALT <= 1'b0;
		l_drive <= 1'b0;
		buffer_upper <= 1'b0;
		time_clr <= 1'b1;
		delay_time <= 14'b00000000000000;
	end
	else
	begin
		new_cmd_d <= new_cmd;
		cmd_done <= 1'b0;

		ack_d <= sd_ack[l_drive];

		delay_time <= delay_time + 1'b1;
		if (time_clr)
			delay_time <= 14'b00000000000000;

		if (rxt_res_end)						// If we read ff4b then we've read the ext_response
			ext_response <= 1'b0;

		case(state)
		state_idle:
		begin
			sdc_busy <= 1'b0;
			sdc_ready <= 1'b0;
			run <= 1'b0;
			wr_cmd <= 1'b0;
			time_clr <= 1'b1;
			transfer_clear <= 1'b1;
			if (new_cmd & ~new_cmd_d)
				if (command[7:3] == CMD_READ)
				begin
					state <= state_read;
				end
				else if (command[7:3] == CMD_WRITE)
				begin
					state <= state_read;
				end
				else if (command[7:3] == CMD_EXT)
				begin
					state <= state_ext;
				end
				else							// no valid command found
				begin
					cmd_done <= 1'b1;
					sdc_fail <= 1'b1;
				end
		end
		state_read:
		begin
			sdc_busy <= 1'b1;
			buffer_upper <= LSN[0];
			l_drive <= command[0];
			ext_response <= 1'b0;			// If we have not read the ext_response by now we are not going too
			transfer_clear <= 1'b0;
			run <= 1'b1;

			if (command[7:3] == CMD_WRITE)
				wr_cmd <= 1'b1;
				
//				Issue sda read command...
			if (~command[0]) 							//  This reference to the drive must be to the command register as l_drive has not yet updated
				sd_lba[0] <= {8'h00, 1'b0, LSN[23:1]};
			else
				sd_lba[1] <= {8'h00, 1'b0, LSN[23:1]};
			state <= state_r1;
		end
		state_r1:
		begin
			sd_rd[l_drive] <= 1'b1;
			state <= state_r1a;
		end
		state_r1a:
			if (sd_ack[l_drive])
			begin
				sd_rd[l_drive] <= 1'b0;
				state <= state_r3;
			end
		state_r3:
		begin
			if (sd_ack[l_drive] & sd_buff_wr & (sd_buff_addr == 9'b111111111))	// wait for the last ack
			begin
				sdc_ready <= 1'b1;
				if (wr_cmd)
					state <= state_write;
				else
					state <= state_r4;
			end
		end
		state_r4:
		begin
			if ((transfer_address == 8'hff) & CLK_EN & SDC_RD & (ADDRESS[3:1] == 3'b101))	// wait for the last read
			begin
				cmd_done <= 1'b1;
				sdc_ready <= 1'b0;
				sdc_busy <= 1'b0;
				state <= state_idle;
			end
		end


		state_write:
		begin
			if ((transfer_address == 8'hff) & CLK_EN & SDC_WR & (ADDRESS[3:1] == 3'b101))	// wait for the last write
			begin
				state <= state_w1;
			end
		end
		state_w1:
		begin
			sdc_HALT <= 1'b1;
			sd_wr[l_drive] <= 1'b1;
			state <= state_w1a;
		end
		state_w1a:
			if (sd_ack[l_drive])
			begin
				sd_wr[l_drive] <= 1'b0;
				state <= state_w3;
			end
		state_w3:
		begin
			time_clr <= 1'b1;
			if (end_ack)		// wait for the end of ack...
			begin
				state <= state_w4;
			end
		end
		state_w4:
		begin
			time_clr <= 1'b0;
			if (delay_time[13])		// wait for .1ms...
			begin
				sdc_HALT <= 1'b0;
				wr_cmd <= 1'b0;

				cmd_done <= 1'b1;
				sdc_ready <= 1'b0;
				sdc_busy <= 1'b0;
				state <= state_idle;
			end
		end

		state_ext:
		begin
			if (LSN[23:16] == 8'H51)			//	This is q [Query]
			begin
				sdc_busy <= 1'b1;
				state <= state_e1;
			end
			else if (LSN[23:16] == 8'H67)		//	This is g [Disable FDC emulation] [Used by OS9]
			begin
				cmd_done <= 1'b1;
				sdc_always <= 1'b1;				// Disable floppy
				state <= state_idle;
			end
			else
			begin
				cmd_done <= 1'b1;				//  All other ext commands...
				sdc_fail <= 1'b1;
				state <= state_idle;
			end
		end

		state_e1:
		begin
			ext_response <= 1'b1;

			`ifdef CoCo3_sdc_override_size
				response_reg <= 24'h555555;						// This fixes a redirect error in OS9EOU  - Value=no hardware
			`else
				response_reg <= drive_size[l_drive][31:8];		// This returns the correct size of the mounted drive in sectors
			`endif
			state <= state_e2;
		end
		
		state_e2:
		begin
			sdc_busy <= 1'b0;
			cmd_done <= 1'b1;
			state <= state_idle;
		end

		endcase

	end
end

wire	[7:0]		hd_buff_data;

wire	[7:0]		sd_buf_out;


// Both drives cannot be executing a read or write at the same time. Both use the same sd sector buffer

assign	sd_buff_din[0] =	sd_buf_out;

assign	sd_buff_din[1] =	sd_buf_out;

sdc_dpram hd_buff
(
	.clock(CLK),
	.address_a(sd_buff_addr),
	.data_a(sd_buff_dout),
	.wren_a(sd_buff_wr & sd_ack[l_drive]),
	.q_a(sd_buf_out),
	
	.address_b({buffer_upper, transfer_address}),
	.data_b(SDC_DATA_IN),
	.wren_b(SDC_EN & CLK_EN & SDC_WR & (ADDRESS[3:1] == 3'b101)),
	.q_b(hd_buff_data)
);

wire	[7:0]	sdc_status;

assign	sdc_status = {sdc_fail, drive_wp[l_drive], 1'b0, ~drive_ready[l_drive], 2'b00, sdc_ready, sdc_busy};

assign	SDC_READ_DATA =	(ADDRESS == ADRS_FF42) 						?	{sdc_data_reg, 4'h0}:
						(ADDRESS == ADRS_FF43) 						?	sdc_status_reg:
						(ADDRESS == ADRS_FF48)					 	?	sdc_status:
						(ADDRESS == ADRS_FF49) 						?	response_reg[23:16]:
						((ADDRESS == ADRS_FF4A) &  ~ext_response)	?	hd_buff_data:
						((ADDRESS == ADRS_FF4A) &  ext_response)	?	response_reg[15:8]:
						((ADDRESS == ADRS_FF4B) &  ~ext_response)	?	hd_buff_data:
						((ADDRESS == ADRS_FF4B) &  ext_response)	?	response_reg[7:0]:
																		8'h00;

endmodule


module sdc_dpram
(
	input	    	 	clock,

	input		[8:0]	address_a,
	input		[7:0]	data_a,
	input	      		wren_a,
	output reg 	[7:0]	q_a,

	input	    [8:0]	address_b,
	input	    [7:0]	data_b,
	input	            wren_b,
	output reg	[7:0]	q_b
);

logic [7:0] ram[0:511];

always_ff@(posedge clock) begin
	if(wren_a) begin
		ram[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram[address_a];
	end
end

always_ff@(posedge clock) begin
	if(wren_b) begin
		ram[address_b] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram[address_b];
	end
end

endmodule