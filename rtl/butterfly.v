////////////////////////////////////////////////////////////////////////////////
//
// Filename:	butterfly.v
//
// Project:	A General Purpose Pipelined FFT Implementation
//
// Purpose:	This routine caculates a butterfly for a decimation
//		in frequency version of an FFT.  Specifically, given
//	complex Left and Right values together with a coefficient, the output
//	of this routine is given by:
//
//		L' = L + R
//		R' = (L - R)*C
//
//	The rest of the junk below handles timing (mostly), to make certain
//	that L' and R' reach the output at the same clock.  Further, just to
//	make certain that is the case, an 'aux' input exists.  This aux value
//	will come out of this routine synchronized to the values it came in
//	with.  (i.e., both L', R', and aux all have the same delay.)  Hence,
//	a caller of this routine may set aux on the first input with valid
//	data, and then wait to see aux set on the output to know when to find
//	the first output with valid data.
//
//	All bits are preserved until the very last clock, where any more bits
//	than OWIDTH will be quietly discarded.
//
//	This design features no overflow checking.
//
// Notes:
//	CORDIC:
//		Much as we might like, we can't use a cordic here.
//		The goal is to accomplish an FFT, as defined, and a
//		CORDIC places a scale factor onto the data.  Removing
//		the scale factor would cost two multiplies, which
//		is precisely what we are trying to avoid.
//
//
//	3-MULTIPLIES:
//		It should also be possible to do this with three multiplies
//		and an extra two addition cycles.
//
//		We want
//			R+I = (a + jb) * (c + jd)
//			R+I = (ac-bd) + j(ad+bc)
//		We multiply
//			P1 = ac
//			P2 = bd
//			P3 = (a+b)(c+d)
//		Then
//			R+I=(P1-P2)+j(P3-P2-P1)
//
//		WIDTHS:
//		On multiplying an X width number by an
//		Y width number, X>Y, the result should be (X+Y)
//		bits, right?
//		-2^(X-1) <= a <= 2^(X-1) - 1
//		-2^(Y-1) <= b <= 2^(Y-1) - 1
//		(2^(Y-1)-1)*(-2^(X-1)) <= ab <= 2^(X-1)2^(Y-1)
//		-2^(X+Y-2)+2^(X-1) <= ab <= 2^(X+Y-2) <= 2^(X+Y-1) - 1
//		-2^(X+Y-1) <= ab <= 2^(X+Y-1)-1
//		YUP!  But just barely.  Do this and you'll really want
//		to drop a bit, although you will risk overflow in so
//		doing.
//
//	20150602 -- The sync logic lines have been completely redone.  The
//		synchronization lines no longer go through the FIFO with the
//		left hand sum, but are kept out of memory.  This allows the
//		butterfly to use more optimal memory resources, while also
//		guaranteeing that the sync lines can be properly reset upon
//		any reset signal.
//
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015-2018, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory, run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	butterfly(i_clk, i_reset, i_ce, i_coef, i_left, i_right, i_aux,
		o_left, o_right, o_aux);
	// Public changeable parameters ...
	parameter IWIDTH=16,CWIDTH=20,OWIDTH=17;
	// Parameters specific to the core that should not be changed.
	parameter	MPYDELAY=4'd11,
			SHIFT=0, AUXLEN=(MPYDELAY+3);
	// The LGDELAY should be the base two log of the MPYDELAY.  If
	// this value is fractional, then round up to the nearest
	// integer: LGDELAY=ceil(log(MPYDELAY)/log(2));
	parameter	LGDELAY=4;
	parameter	CKPCE=1;
	input		i_clk, i_reset, i_ce;
	input		[(2*CWIDTH-1):0] i_coef;
	input		[(2*IWIDTH-1):0] i_left, i_right;
	input		i_aux;
	output	wire	[(2*OWIDTH-1):0] o_left, o_right;
	output	reg	o_aux;

	reg	[(2*IWIDTH-1):0]	r_left, r_right;
	reg	[(2*CWIDTH-1):0]	r_coef, r_coef_2;
	wire	signed	[(IWIDTH-1):0]	r_left_r, r_left_i, r_right_r, r_right_i;
	assign	r_left_r  = r_left[ (2*IWIDTH-1):(IWIDTH)];
	assign	r_left_i  = r_left[ (IWIDTH-1):0];
	assign	r_right_r = r_right[(2*IWIDTH-1):(IWIDTH)];
	assign	r_right_i = r_right[(IWIDTH-1):0];

	reg	signed	[(IWIDTH):0]	r_sum_r, r_sum_i, r_dif_r, r_dif_i;

	reg	[(LGDELAY-1):0]	fifo_addr;
	wire	[(LGDELAY-1):0]	fifo_read_addr;
	assign	fifo_read_addr = fifo_addr - MPYDELAY[(LGDELAY-1):0];
	reg	[(2*IWIDTH+1):0]	fifo_left [ 0:((1<<LGDELAY)-1)];

	// Set up the input to the multiply
	always @(posedge i_clk)
		if (i_ce)
		begin
			// One clock just latches the inputs
			r_left <= i_left;	// No change in # of bits
			r_right <= i_right;
			r_coef  <= i_coef;
			// Next clock adds/subtracts
			r_sum_r <= r_left_r + r_right_r; // Now IWIDTH+1 bits
			r_sum_i <= r_left_i + r_right_i;
			r_dif_r <= r_left_r - r_right_r;
			r_dif_i <= r_left_i - r_right_i;
			// Other inputs are simply delayed on second clock
			r_coef_2<= r_coef;
		end

	// Don't forget to record the even side, since it doesn't need
	// to be multiplied, but yet we still need the results in sync
	// with the answer when it is ready.
	initial fifo_addr = 0;
	always @(posedge i_clk)
		if (i_reset)
			fifo_addr <= 0;
		else if (i_ce)
			// Need to delay the sum side--nothing else happens
			// to it, but it needs to stay synchronized with the
			// right side.
			fifo_addr <= fifo_addr + 1;

	always @(posedge i_clk)
		if (i_ce)
			fifo_left[fifo_addr] <= { r_sum_r, r_sum_i };

	wire	signed	[(CWIDTH-1):0]	ir_coef_r, ir_coef_i;
	assign	ir_coef_r = r_coef_2[(2*CWIDTH-1):CWIDTH];
	assign	ir_coef_i = r_coef_2[(CWIDTH-1):0];
	wire	signed	[((IWIDTH+2)+(CWIDTH+1)-1):0]	p_one, p_two, p_three;


	// Multiply output is always a width of the sum of the widths of
	// the two inputs.  ALWAYS.  This is independent of the number of
	// bits in p_one, p_two, or p_three.  These values needed to
	// accumulate a bit (or two) each.  However, this approach to a
	// three multiply complex multiply cannot increase the total
	// number of bits in our final output.  We'll take care of
	// dropping back down to the proper width, OWIDTH, in our routine
	// below.


	// We accomplish here "Karatsuba" multiplication.  That is,
	// by doing three multiplies we accomplish the work of four.
	// Let's prove to ourselves that this works ... We wish to
	// multiply: (a+jb) * (c+jd), where a+jb is given by
	//	a + jb = r_dif_r + j r_dif_i, and
	//	c + jd = ir_coef_r + j ir_coef_i.
	// We do this by calculating the intermediate products P1, P2,
	// and P3 as
	//	P1 = ac
	//	P2 = bd
	//	P3 = (a + b) * (c + d)
	// and then complete our final answer with
	//	ac - bd = P1 - P2 (this checks)
	//	ad + bc = P3 - P2 - P1
	//	        = (ac + bc + ad + bd) - bd - ac
	//	        = bc + ad (this checks)


	// This should really be based upon an IF, such as in
	// if (IWIDTH < CWIDTH) then ...
	// However, this is the only (other) way I know to do it.
	generate if (CKPCE <= 1)
	begin

		wire	[(CWIDTH):0]	p3c_in;
		wire	[(IWIDTH+1):0]	p3d_in;
		assign	p3c_in = ir_coef_i + ir_coef_r;
		assign	p3d_in = r_dif_r + r_dif_i;

		// We need to pad these first two multiplies by an extra
		// bit just to keep them aligned with the third,
		// simpler, multiply.
		longbimpy #(CWIDTH+1,IWIDTH+2) p1(i_clk, i_ce,
				{ir_coef_r[CWIDTH-1],ir_coef_r},
				{r_dif_r[IWIDTH],r_dif_r}, p_one);
		longbimpy #(CWIDTH+1,IWIDTH+2) p2(i_clk, i_ce,
				{ir_coef_i[CWIDTH-1],ir_coef_i},
				{r_dif_i[IWIDTH],r_dif_i}, p_two);
		longbimpy #(CWIDTH+1,IWIDTH+2) p3(i_clk, i_ce,
				p3c_in, p3d_in, p_three);

	end else if (CKPCE == 2)
	begin : CKPCE_TWO
		// Coefficient multiply inputs
		reg		[2*(CWIDTH)-1:0]	mpy_pipe_c;
		// Data multiply inputs
		reg		[2*(IWIDTH+1)-1:0]	mpy_pipe_d;
		wire	signed	[(CWIDTH-1):0]	mpy_pipe_vc;
		wire	signed	[(IWIDTH):0]	mpy_pipe_vd;
		//
		reg	signed	[(CWIDTH+1)-1:0]	mpy_cof_sum;
		reg	signed	[(IWIDTH+2)-1:0]	mpy_dif_sum;

		assign	mpy_pipe_vc =  mpy_pipe_c[2*(CWIDTH)-1:CWIDTH];
		assign	mpy_pipe_vd =  mpy_pipe_d[2*(IWIDTH+1)-1:IWIDTH+1];

		reg			mpy_pipe_v;
		reg			ce_phase;

		reg	signed	[(CWIDTH+IWIDTH+1)-1:0]	mpy_pipe_out;
		reg	signed [IWIDTH+CWIDTH+3-1:0]	longmpy;


		initial	ce_phase = 1'b0;
		always @(posedge i_clk)
		if (i_reset)
			ce_phase <= 1'b0;
		else if (i_ce)
			ce_phase <= 1'b1;
		else
			ce_phase <= 1'b0;

		always @(*)
			mpy_pipe_v = (i_ce)||(ce_phase);

		always @(posedge i_clk)
		if (ce_phase)
		begin
			// Pre-clock
			mpy_pipe_c[2*CWIDTH-1:0] <=
					{ ir_coef_r, ir_coef_i };
			mpy_pipe_d[2*(IWIDTH+1)-1:0] <=
					{ r_dif_r, r_dif_i };

			mpy_cof_sum  <= ir_coef_i + ir_coef_r;
			mpy_dif_sum <= r_dif_r + r_dif_i;

		end else if (i_ce)
		begin
			// First clock
			mpy_pipe_c[2*(CWIDTH)-1:0] <= {
				mpy_pipe_c[(CWIDTH)-1:0], {(CWIDTH){1'b0}} };
			mpy_pipe_d[2*(IWIDTH+1)-1:0] <= {
				mpy_pipe_d[(IWIDTH+1)-1:0], {(IWIDTH+1){1'b0}} };
		end

		longbimpy #(CWIDTH+1,IWIDTH+2) mpy0(i_clk, mpy_pipe_v,
				mpy_cof_sum, mpy_dif_sum, longmpy);

		longbimpy #(CWIDTH,IWIDTH+1) mpy1(i_clk, mpy_pipe_v,
				mpy_pipe_vc, mpy_pipe_vd, mpy_pipe_out);

		reg	signed	[((IWIDTH+1)+(CWIDTH)-1):0]	rp_one;
		reg	signed	[((IWIDTH+1)+(CWIDTH)-1):0]	rp2_one,
								rp_two;
		reg	signed	[((IWIDTH+2)+(CWIDTH+1)-1):0]	rp_three;

		always @(posedge i_clk)
		if (ce_phase) // 1.5 clock
			rp_one <= mpy_pipe_out;
		always @(posedge i_clk)
		if (i_ce) // two clocks
			rp_two <= mpy_pipe_out;
		always @(posedge i_clk)
		if (i_ce) // Second clock
			rp_three<= longmpy;
		always @(posedge i_clk)
		if (i_ce)
			rp2_one<= rp_one;

		assign	p_one	= { {(2){rp2_one[(IWIDTH+1)+(CWIDTH)-1]}}, rp2_one };
		assign	p_two	= { {(2){rp_two[(IWIDTH+1)+(CWIDTH)-1]}}, rp_two };
		assign	p_three	= rp_three;

	end else if (CKPCE <= 3)
	begin : CKPCE_THREE
		// Coefficient multiply inputs
		reg		[3*(CWIDTH+1)-1:0]	mpy_pipe_c;
		// Data multiply inputs
		reg		[3*(IWIDTH+2)-1:0]	mpy_pipe_d;
		wire	signed	[(CWIDTH):0]	mpy_pipe_vc;
		wire	signed	[(IWIDTH+1):0]	mpy_pipe_vd;

		assign	mpy_pipe_vc =  mpy_pipe_c[3*(CWIDTH+1)-1:2*(CWIDTH+1)];
		assign	mpy_pipe_vd =  mpy_pipe_d[3*(IWIDTH+2)-1:2*(IWIDTH+2)];

		reg			mpy_pipe_v;
		reg		[2:0]	ce_phase;

		reg	signed	[  (CWIDTH+IWIDTH+3)-1:0]	mpy_pipe_out;

		initial	ce_phase = 3'b011;
		always @(posedge i_clk)
		if (i_reset)
			ce_phase <= 3'b011;
		else if (i_ce)
			ce_phase <= 3'b000;
		else if (ce_phase != 3'b011)
			ce_phase <= ce_phase + 1'b1;

		always @(*)
			mpy_pipe_v = (i_ce)||(ce_phase < 3'b010);

		always @(posedge i_clk)
			if (ce_phase == 3'b000)
			begin
				// Second clock
				mpy_pipe_c[3*(CWIDTH+1)-1:(CWIDTH+1)] <= {
					ir_coef_r[CWIDTH-1], ir_coef_r,
					ir_coef_i[CWIDTH-1], ir_coef_i };
				mpy_pipe_c[CWIDTH:0] <= ir_coef_i + ir_coef_r;
				mpy_pipe_d[3*(IWIDTH+2)-1:(IWIDTH+2)] <= {
					r_dif_r[IWIDTH], r_dif_r,
					r_dif_i[IWIDTH], r_dif_i };
				mpy_pipe_d[(IWIDTH+2)-1:0] <= r_dif_r + r_dif_i;

			end else if (mpy_pipe_v)
			begin
				mpy_pipe_c[3*(CWIDTH+1)-1:0] <= {
					mpy_pipe_c[2*(CWIDTH+1)-1:0], {(CWIDTH+1){1'b0}} };
				mpy_pipe_d[3*(IWIDTH+2)-1:0] <= {
					mpy_pipe_d[2*(IWIDTH+2)-1:0], {(IWIDTH+2){1'b0}} };
			end

		longbimpy #(CWIDTH+1,IWIDTH+2) mpy(i_clk, mpy_pipe_v,
				mpy_pipe_vc, mpy_pipe_vd, mpy_pipe_out);

		reg	signed	[((IWIDTH+1)+(CWIDTH)-1):0]	rp_one, rp_two;
		reg	signed	[((IWIDTH+1)+(CWIDTH)-1):0]	rp2_one, rp2_two;
		reg	signed	[((IWIDTH+2)+(CWIDTH+1)-1):0]	rp_three, rp2_three;

		always @(posedge i_clk)
		if(i_ce)
			rp_one <= mpy_pipe_out[(CWIDTH+IWIDTH+3)-3:0];
		always @(posedge i_clk)
		if(ce_phase == 3'b000)
			rp_two <= mpy_pipe_out[(CWIDTH+IWIDTH+3)-3:0];
		always @(posedge i_clk)
		if(ce_phase == 3'b001)
			rp_three <= mpy_pipe_out;
		always @(posedge i_clk)
		if (i_ce)
		begin
			rp2_one<= rp_one;
			rp2_two<= rp_two;
			rp2_three<= rp_three;
		end
		assign	p_one	= rp2_one;
		assign	p_two	= rp2_two;
		assign	p_three	= rp2_three;

	end endgenerate
	// These values are held in memory and delayed during the
	// multiply.  Here, we recover them.  During the multiply,
	// values were multiplied by 2^(CWIDTH-2)*exp{-j*2*pi*...},
	// therefore, the left_x values need to be right shifted by
	// CWIDTH-2 as well.  The additional bits come from a sign
	// extension.
	wire	signed	[(IWIDTH+CWIDTH):0]	fifo_i, fifo_r;
	reg		[(2*IWIDTH+1):0]	fifo_read;
	assign	fifo_r = { {2{fifo_read[2*(IWIDTH+1)-1]}}, fifo_read[(2*(IWIDTH+1)-1):(IWIDTH+1)], {(CWIDTH-2){1'b0}} };
	assign	fifo_i = { {2{fifo_read[(IWIDTH+1)-1]}}, fifo_read[((IWIDTH+1)-1):0], {(CWIDTH-2){1'b0}} };


	reg	signed	[(CWIDTH+IWIDTH+3-1):0]	mpy_r, mpy_i;

	// Let's do some rounding and remove unnecessary bits.
	// We have (IWIDTH+CWIDTH+3) bits here, we need to drop down to
	// OWIDTH, and SHIFT by SHIFT bits in the process.  The trick is
	// that we don't need (IWIDTH+CWIDTH+3) bits.  We've accumulated
	// them, but the actual values will never fill all these bits.
	// In particular, we only need:
	//	 IWIDTH bits for the input
	//	     +1 bit for the add/subtract
	//	+CWIDTH bits for the coefficient multiply
	//	     +1 bit for the add/subtract in the complex multiply
	//	 ------
	//	 (IWIDTH+CWIDTH+2) bits at full precision.
	//
	// However, the coefficient multiply multiplied by a maximum value
	// of 2^(CWIDTH-2).  Thus, we only have
	//	   IWIDTH bits for the input
	//	       +1 bit for the add/subtract
	//	+CWIDTH-2 bits for the coefficient multiply
	//	       +1 (optional) bit for the add/subtract in the cpx mpy.
	//	 -------- ... multiply.  (This last bit may be shifted out.)
	//	 (IWIDTH+CWIDTH) valid output bits.
	// Now, if the user wants to keep any extras of these (via OWIDTH),
	// or if he wishes to arbitrarily shift some of these off (via
	// SHIFT) we accomplish that here.

	wire	signed	[(OWIDTH-1):0]	rnd_left_r, rnd_left_i, rnd_right_r, rnd_right_i;

	wire	signed	[(CWIDTH+IWIDTH+3-1):0]	left_sr, left_si;
	assign	left_sr = { {(2){fifo_r[(IWIDTH+CWIDTH)]}}, fifo_r };
	assign	left_si = { {(2){fifo_i[(IWIDTH+CWIDTH)]}}, fifo_i };

	convround #(CWIDTH+IWIDTH+3,OWIDTH,SHIFT+4) do_rnd_left_r(i_clk, i_ce,
				left_sr, rnd_left_r);

	convround #(CWIDTH+IWIDTH+3,OWIDTH,SHIFT+4) do_rnd_left_i(i_clk, i_ce,
				left_si, rnd_left_i);

	convround #(CWIDTH+IWIDTH+3,OWIDTH,SHIFT+4) do_rnd_right_r(i_clk, i_ce,
				mpy_r, rnd_right_r);

	convround #(CWIDTH+IWIDTH+3,OWIDTH,SHIFT+4) do_rnd_right_i(i_clk, i_ce,
				mpy_i, rnd_right_i);

	always @(posedge i_clk)
		if (i_ce)
		begin
			// First clock, recover all values
			fifo_read <= fifo_left[fifo_read_addr];
			// These values are IWIDTH+CWIDTH+3 bits wide
			// although they only need to be (IWIDTH+1)
			// + (CWIDTH) bits wide.  (We've got two
			// extra bits we need to get rid of.)
			mpy_r <= p_one - p_two;
			mpy_i <= p_three - p_one - p_two;
		end

	reg	[(AUXLEN-1):0]	aux_pipeline;
	initial	aux_pipeline = 0;
	always @(posedge i_clk)
		if (i_reset)
			aux_pipeline <= 0;
		else if (i_ce)
			aux_pipeline <= { aux_pipeline[(AUXLEN-2):0], i_aux };

	initial o_aux = 1'b0;
	always @(posedge i_clk)
		if (i_reset)
			o_aux <= 1'b0;
		else if (i_ce)
		begin
			// Second clock, latch for final clock
			o_aux <= aux_pipeline[AUXLEN-1];
		end

	// As a final step, we pack our outputs into two packed two's
	// complement numbers per output word, so that each output word
	// has (2*OWIDTH) bits in it, with the top half being the real
	// portion and the bottom half being the imaginary portion.
	assign	o_left = { rnd_left_r, rnd_left_i };
	assign	o_right= { rnd_right_r,rnd_right_i};

`ifdef	FORMAL
	localparam	F_LGDEPTH = 5;
	localparam	F_DEPTH = AUXLEN;
	localparam	F_D = F_DEPTH-1;

	reg	signed	[IWIDTH-1:0]	f_dlyleft_r  [0:F_DEPTH-1];
	reg	signed	[IWIDTH-1:0]	f_dlyleft_i  [0:F_DEPTH-1];
	reg	signed	[IWIDTH-1:0]	f_dlyright_r [0:F_DEPTH-1];
	reg	signed	[IWIDTH-1:0]	f_dlyright_i [0:F_DEPTH-1];
	reg	signed	[CWIDTH-1:0]	f_dlycoeff_r [0:F_DEPTH-1];
	reg	signed	[CWIDTH-1:0]	f_dlycoeff_i [0:F_DEPTH-1];
	reg	signed	[F_DEPTH-1:0]	f_dlyaux;

	always @(posedge i_clk)
	if (i_ce)
	begin
		f_dlyleft_r[0]   <= i_left[ (2*IWIDTH-1):IWIDTH];
		f_dlyleft_i[0]   <= i_left[ (  IWIDTH-1):0];
		f_dlyright_r[0]  <= i_right[(2*IWIDTH-1):IWIDTH];
		f_dlyright_i[0]  <= i_right[(  IWIDTH-1):0];
		f_dlycoeff_r[0]  <= i_coef[ (2*CWIDTH-1):CWIDTH];
		f_dlycoeff_i[0]  <= i_coef[ (  CWIDTH-1):0];
		f_dlyaux[0]      <= i_aux;
	end

	genvar	k;
	generate for(k=1; k<F_DEPTH; k=k+1)

		always @(posedge i_clk)
		if (i_ce)
		begin
			f_dlyleft_r[k]  <= f_dlyleft_r[ k-1];
			f_dlyleft_i[k]  <= f_dlyleft_i[ k-1];
			f_dlyright_r[k] <= f_dlyright_r[k-1];
			f_dlyright_i[k] <= f_dlyright_i[k-1];
			f_dlycoeff_r[k] <= f_dlycoeff_r[k-1];
			f_dlycoeff_i[k] <= f_dlycoeff_i[k-1];
			f_dlyaux[k]     <= f_dlyaux[    k-1];
		end

	endgenerate

	always @(posedge i_clk)
	if ((!$past(i_ce))&&(!$past(i_ce,2))&&(!$past(i_ce,3))
			&&(!$past(i_ce,4)))
		assume(i_ce);

	generate if (CKPCE <= 1)
	begin

		// i_ce is allowed to be anything in this mode

	end else if (CKPCE == 2)
	begin : F_CKPCE_TWO

		always @(posedge i_clk)
			if ($past(i_ce))
				assume(!i_ce);

	end else if (CKPCE == 3)
	begin : F_CKPCE_THREE

		always @(posedge i_clk)
			if (($past(i_ce))||($past(i_ce,2)))
				assume(!i_ce);

	end endgenerate

	reg	[F_LGDEPTH-1:0]	f_startup_counter;
	initial	f_startup_counter = 0;
	always @(posedge i_clk)
	if (i_reset)
		f_startup_counter = 0;
	else if ((i_ce)&&(!(&f_startup_counter)))
		f_startup_counter <= f_startup_counter + 1;

	wire	signed	[IWIDTH:0]	f_sumr, f_sumi;
	always @(*)
	begin
		f_sumr = f_dlyleft_r[F_D] + f_dlyright_r[F_D];
		f_sumi = f_dlyleft_i[F_D] + f_dlyright_i[F_D];
	end

	wire	signed	[IWIDTH+CWIDTH-1:0]	f_sumrx, f_sumix;
	assign	f_sumrx = { {(2){f_sumr[IWIDTH]}}, f_sumr, {(CWIDTH-2){1'b0}} };
	assign	f_sumix = { {(2){f_sumi[IWIDTH]}}, f_sumi, {(CWIDTH-2){1'b0}} };

	wire	signed	[IWIDTH:0]	f_difr, f_difi;
	always @(*)
	begin
		f_difr = f_dlyleft_r[F_D] - f_dlyright_r[F_D];
		f_difi = f_dlyleft_i[F_D] - f_dlyright_i[F_D];
	end

	wire	signed	[IWIDTH+CWIDTH-1:0]	f_difrx, f_difix;
	assign	f_difrx = { {(CWIDTH){f_difr[IWIDTH]}}, f_difr };
	assign	f_difix = { {(CWIDTH){f_difi[IWIDTH]}}, f_difi };


	always @(posedge i_clk)
	if (f_startup_counter > F_D)
	begin
		assert(left_sr == f_sumrx);
		assert(left_si == f_sumix);
		assert(aux_pipeline[AUXLEN-1] == f_dlyaux[F_D]);

		if ((f_difr == 0)&&(f_difi == 0))
		begin
			assert(mpy_r == 0);
			assert(mpy_i == 0);
		end else if ((f_dlycoeff_r[F_D] == 0)
				&&(f_dlycoeff_i[F_D] == 0))
		begin
			assert(mpy_r == 0);
			assert(mpy_i == 0);
		end

		if ((f_dlycoeff_r[F_D] == 1)&&(f_dlycoeff_i[F_D] == 0))
		begin
			assert(mpy_r == f_difrx);
			assert(mpy_i == f_difix);
		end

		if ((f_dlycoeff_r[F_D] == 0)&&(f_dlycoeff_i[F_D] == 1))
		begin
			assert(mpy_r == -f_difix);
			assert(mpy_i ==  f_difrx);
		end

		if ((f_difr == 1)&&(f_difi == 0))
		begin
			assert(mpy_r == f_dlycoeff_r[F_D]);
			assert(mpy_i == f_dlycoeff_i[F_D]);
		end

		if ((f_difr == 0)&&(f_difi == 1))
		begin
			assert(mpy_r == -f_dlycoeff_i[F_D]);
			assert(mpy_i ==  f_dlycoeff_r[F_D]);
		end
	end

`endif
endmodule