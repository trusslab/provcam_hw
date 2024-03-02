////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	axixbar.v
// {{{
// Project:	WB2AXIPSP: bus bridges and other odds and ends
//
// Purpose:	Create a full crossbar between NM AXI sources (masters), and NS
//		AXI slaves.  Every master can talk to any slave, provided it
//	isn't already busy.
// {{{
// Performance:	This core has been designed with the goal of being able to push
//		one transaction through the interconnect, from any master to
//	any slave, per clock cycle.  This may perhaps be its most unique
//	feature.  While throughput is good, latency is something else.
//
//	The arbiter requires a clock to switch, then another clock to send data
//	downstream.  This creates a minimum two clock latency up front.  The
//	return path suffers another clock of latency as well, placing the
//	minimum latency at four clocks.  The minimum write latency is at
//	least one clock longer, since the write data must wait for the write
//	address before proceeeding.
//
//	Note that this arbiter only forwards AxID fields.  It does not use
//	them in arbitration.  As a result, only one master may ever make
//	requests of any given slave at a time.  All responses from a slave
//	will be returned to that known master.  This is a known limitation in
//	this implementation which will be fixed (in time) with funding and
//	interest.  Until that time, in order for a second master to access
//	a given slave, the first master must receive all of its acknowledgments.
//
// Usage:	To use, you must first set NM and NS to the number of masters
//	and the number of slaves you wish to connect to.  You then need to
//	adjust the addresses of the slaves, found SLAVE_ADDR array.  Those
//	bits that are relevant in SLAVE_ADDR to then also be set in SLAVE_MASK.
//	Adjusting the data and address widths go without saying.
//
//	Lower numbered masters are given priority in any "fight".
//
//	Channel grants are given on the condition that 1) they are requested,
//	2) no other channel has a grant, 3) all of the responses have been
//	received from the current channel, and 4) the internal counters are
//	not overflowing.
//
//	The core limits the number of outstanding transactions on any channel to
//	1<<LGMAXBURST-1.
//
//	Channel grants are lost 1) after OPT_LINGER clocks of being idle, or
//	2) when another master requests an idle (but still lingering) channel
//	assignment, or 3) once all the responses have been returned to the
//	current channel, and the current master is requesting another channel.
//
//	A special slave is allocated for the case of no valid address.
//
//	Since the write channel has no address information, the write data
//	channel always be delayed by at least one clock from the write address
//	channel.
//
//	If OPT_LOWPOWER is set, then unused values will be set to zero.
//	This can also be used to help identify relevant values within any
//	trace.
//
// Known issues: This module can be a challenge to wire up.
//
//	In order to keep the build lint clean, it's important that every
//	port be connected.  In order to be flexible regarding the number of
//	ports that can be connected, the various AXI signals, whether input
//	or output, have been concatenated together across either all masters
//	or all slaves.  This can make the design a lesson in tediousness to
//	wire up.
//
//	I commonly wire this crossbar up using AutoFPGA--just to make certain
//	that I do it right and don't make mistakes when wiring it up.  This
//	also handles the tediousness involved.
//
//	I have also done this by hand.
//
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
// }}}
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2019-2022, Gisselquist Technology, LLC
// {{{
// This file is part of the WB2AXIP project.
//
// The WB2AXIP project contains free software and gateware, licensed under the
// Apache License, Version 2.0 (the "License").  You may not use this project,
// or this file, except in compliance with the License.  You may obtain a copy
// of the License at
//
//	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
// License for the specific language governing permissions and limitations
// under the License.
//
////////////////////////////////////////////////////////////////////////////////
//
`default_nettype none
// }}}
module	axixbar #(
		// {{{d12s
		parameter integer C_AXI_DATA_WIDTH = 128,
		parameter integer C_AXI_ADDR_WIDTH = 44,
		parameter integer C_AXI_ID_WIDTH = 4,
		//
		// NM is the number of masters driving the incoming slave chnls
		parameter	NM = 1,
		//
		// NS is the number of slaves connected to the crossbar, driven
		// by the master channels output from this IP.
		parameter	NS = 1,
		//
		// SLAVE_ADDR is an array of addresses, describing each of
		// {{{
		// the slave channels.  It works tightly with SLAVE_MASK,
		// so that when (ADDR & MASK == ADDR), the channel in question
		// has been requested.
		//
		// It is an internal in the setup of this core to doubly map
		// an address, such that (addr & SLAVE_MASK[k])==SLAVE_ADDR[k]
		// for two separate values of k.
		//
		// Any attempt to access an address that is a hole in this
		// address list will result in a returned xRESP value of
		// INTERCONNECT_ERROR (2'b11)
		//
		// NOTE: This is only a nominal address set.  I expect that
		// any design using the crossbar will need to adjust both
		// SLAVE_ADDR and SLAVE_MASK, if not also NM and NS.
		parameter	[NS*C_AXI_ADDR_WIDTH-1:0]	SLAVE_ADDR = {
			{(C_AXI_ADDR_WIDTH-3){1'b0}}},
		// }}}
		//
		// SLAVE_MASK: is an array, much like SLAVE_ADDR, describing
		// {{{
		// which of the bits in SLAVE_ADDR are relevant.  It is
		// important to maintain for every slave that
		// 	(~SLAVE_MASK[i] & SLAVE_ADDR[i]) == 0.
		//
		// NOTE: This value should be overridden by any implementation.
		// Verilator lint_off WIDTH
		parameter	[NS*C_AXI_ADDR_WIDTH-1:0]	SLAVE_MASK = {
			{(C_AXI_ADDR_WIDTH){1'b0}} },
		// Verilator lint_on  WIDTH
		// }}}
		//
		// OPT_LOWPOWER: If set, it forces all unused values to zero,
		// {{{
		// preventing them from unnecessarily toggling.  This will
		// raise the logic count of the core, but might also lower
		// the power used by the interconnect and the bus driven wires
		// which (in my experience) tend to have a high fan out.
		// parameter [0:0]	OPT_LOWPOWER = 0,
		parameter [0:0]	OPT_LOWPOWER = 0,
		// }}}
		//
		// OPT_LINGER: Set this to the number of clocks an idle
		// {{{
		// channel shall be left open before being closed.  Once
		// closed, it will take a minimum of two clocks before the
		// channel can be opened and data transmitted through it again.
		// parameter	OPT_LINGER = 4,
		parameter	OPT_LINGER = 8,
		// }}}
		//
		// [EXPERIMENTAL] OPT_QOS: If set, the QOS transmission values
		// {{{
		// will be honored when determining who wins arbitration for
		// accessing a given slave.  (This feature has not yet been
		// verified)
		parameter [0:0]	OPT_QOS = 0,
		// }}}
		//
		// LGMAXBURST: Specifies the log based two of the maximum
		// {{{
		// number of bursts transactions that may be outstanding at any
		// given time.  This is different from the maximum number of
		// outstanding beats.
		parameter	LGMAXBURST = 33,
		// }}}
		// }}}

        // Myles: sha256 parameters
        parameter    [7:0]     MAXSTOREDFIRSTVALUE = 16,    // 16 
        parameter    [7:0]     MAXSTOREDFIRSTVALUE4PTR = 15,   // 63
        parameter    [11:0]    MAXBITSSTOREDONEBLOCK = 512,

		// encoded rob parameters
		parameter MEM_DDEPTH_4_E = 64,
		parameter MEM_AWIDTH_4_E = 10,

		// r frame parameters
		parameter [11:0] PIXEL_Y_SIZE_IN_BITS = 8,
		parameter [11:0] PIXEL_UV_SIZE_IN_BITS = 4,
		parameter [11:0] FRAME_WIDTH = 1280,
		parameter [11:0] FRAME_HEIGHT = 720,
		parameter [11:0] ENCODER_BLOCK_HEIGHT = 16,
		
		// e frame parameters
		parameter [3:0] NUM_OF_SLICES_PER_FRAME = 8,

        // Myles: uram parameters
        // mem_size = MEM_DWIDTH * 2^MEM_AWIDTH
        parameter MEM_AWIDTH = 13,  // Address Width
        parameter MEM_DWIDTH = 128,  // Data Width

		// sha256 RAW(R/r)
		parameter SHA256_RST_NUM_OF_CLOCKS = 10,
		parameter SHA256_LAST_BLOCK_DELAY_NUM_OF_CLOCKS = 10,
		parameter    [6:0]    SHA256_BLOCK_SIZE_IN_BYTES = 64,
		parameter	[8:0]    SHA256_HASH_SIZE_IN_BITS = 256,

		// r_hasher
		parameter [31:0] R_FRAME_Y_START_ADDR = 32'hc400000,

		// for switching slice in e_hasher
		parameter [3:0] SLICE_SWITCHING_DELAY = 4
	) (
		// {{{
		input	wire	S_AXI_ACLK,
		input	wire	S_AXI_ARESETN,
		// Write slave channels from the controlling AXI masters
		// {{{
		input	wire	[NM*C_AXI_ID_WIDTH-1:0]		S_AXI_AWID,
		input	wire	[NM*C_AXI_ADDR_WIDTH-1:0]	S_AXI_AWADDR,
		input	wire	[NM*8-1:0]			S_AXI_AWLEN,
		input	wire	[NM*3-1:0]			S_AXI_AWSIZE,
		input	wire	[NM*2-1:0]			S_AXI_AWBURST,
		input	wire	[NM-1:0]			S_AXI_AWLOCK,
		input	wire	[NM*4-1:0]			S_AXI_AWCACHE,
		input	wire	[NM*3-1:0]			S_AXI_AWPROT,
		input	wire	[NM*4-1:0]			S_AXI_AWQOS,
		input	wire	[NM-1:0]			S_AXI_AWVALID,
		output	wire	[NM-1:0]			S_AXI_AWREADY,
		//
		input	wire	[NM*C_AXI_DATA_WIDTH-1:0]	S_AXI_WDATA,
		input	wire	[NM*C_AXI_DATA_WIDTH/8-1:0]	S_AXI_WSTRB,
		input	wire	[NM-1:0]			S_AXI_WLAST,
		input	wire	[NM-1:0]			S_AXI_WVALID,
		output	wire	[NM-1:0]			S_AXI_WREADY,
		//
		output	wire	[NM*C_AXI_ID_WIDTH-1:0]		S_AXI_BID,
		output	wire	[NM*2-1:0]			S_AXI_BRESP,
		output	wire	[NM-1:0]			S_AXI_BVALID,
		input	wire	[NM-1:0]			S_AXI_BREADY,
		// }}}
		// Read slave channels from the controlling AXI masters
		// {{{
		input	wire	[NM*C_AXI_ID_WIDTH-1:0]		S_AXI_ARID,
		input	wire	[NM*C_AXI_ADDR_WIDTH-1:0]	S_AXI_ARADDR,
		input	wire	[NM*8-1:0]			S_AXI_ARLEN,
		input	wire	[NM*3-1:0]			S_AXI_ARSIZE,
		input	wire	[NM*2-1:0]			S_AXI_ARBURST,
		input	wire	[NM-1:0]			S_AXI_ARLOCK,
		input	wire	[NM*4-1:0]			S_AXI_ARCACHE,
		input	wire	[NM*3-1:0]			S_AXI_ARPROT,
		input	wire	[NM*4-1:0]			S_AXI_ARQOS,
		input	wire	[NM-1:0]			S_AXI_ARVALID,
		output	wire	[NM-1:0]			S_AXI_ARREADY,
		//
		output	wire	[NM*C_AXI_ID_WIDTH-1:0]		S_AXI_RID,
		output	wire	[NM*C_AXI_DATA_WIDTH-1:0]	S_AXI_RDATA,
		output	wire	[NM*2-1:0]			S_AXI_RRESP,
		output	wire	[NM-1:0]			S_AXI_RLAST,
		output	wire	[NM-1:0]			S_AXI_RVALID,
		input	wire	[NM-1:0]			S_AXI_RREADY,
		// }}}
		// Write channel master outputs to the connected AXI slaves
		// {{{
		output	wire	[NS*C_AXI_ID_WIDTH-1:0]		M_AXI_AWID,
		output	wire	[NS*C_AXI_ADDR_WIDTH-1:0]	M_AXI_AWADDR,
		output	wire	[NS*8-1:0]			M_AXI_AWLEN,
		output	wire	[NS*3-1:0]			M_AXI_AWSIZE,
		output	wire	[NS*2-1:0]			M_AXI_AWBURST,
		output	wire	[NS-1:0]			M_AXI_AWLOCK,
		output	wire	[NS*4-1:0]			M_AXI_AWCACHE,
		output	wire	[NS*3-1:0]			M_AXI_AWPROT,
		output	wire	[NS*4-1:0]			M_AXI_AWQOS,
		output	wire	[NS-1:0]			M_AXI_AWVALID,
		input	wire	[NS-1:0]			M_AXI_AWREADY,
		//
		//
		output	wire	[NS*C_AXI_DATA_WIDTH-1:0]	M_AXI_WDATA,
		output	wire	[NS*C_AXI_DATA_WIDTH/8-1:0]	M_AXI_WSTRB,
		output	wire	[NS-1:0]			M_AXI_WLAST,
		output	wire	[NS-1:0]			M_AXI_WVALID,
		input	wire	[NS-1:0]			M_AXI_WREADY,
		//
		input	wire	[NS*C_AXI_ID_WIDTH-1:0]		M_AXI_BID,
		input	wire	[NS*2-1:0]			M_AXI_BRESP,
		input	wire	[NS-1:0]			M_AXI_BVALID,
		output	wire	[NS-1:0]			M_AXI_BREADY,
		// }}}
		// Read channel master outputs to the connected AXI slaves
		// {{{
		output	wire	[NS*C_AXI_ID_WIDTH-1:0]		M_AXI_ARID,
		output	wire	[NS*C_AXI_ADDR_WIDTH-1:0]	M_AXI_ARADDR,
		output	wire	[NS*8-1:0]			M_AXI_ARLEN,
		output	wire	[NS*3-1:0]			M_AXI_ARSIZE,
		output	wire	[NS*2-1:0]			M_AXI_ARBURST,
		output	wire	[NS-1:0]			M_AXI_ARLOCK,
		output	wire	[NS*4-1:0]			M_AXI_ARCACHE,
		output	wire	[NS*4-1:0]			M_AXI_ARQOS,
		output	wire	[NS*3-1:0]			M_AXI_ARPROT,
		output	wire	[NS-1:0]			M_AXI_ARVALID,
		input	wire	[NS-1:0]			M_AXI_ARREADY,
		//
		//
		input	wire	[NS*C_AXI_ID_WIDTH-1:0]		M_AXI_RID,
		input	wire	[NS*C_AXI_DATA_WIDTH-1:0]	M_AXI_RDATA,
		input	wire	[NS*2-1:0]			M_AXI_RRESP,
		input	wire	[NS-1:0]			M_AXI_RLAST,
		input	wire	[NS-1:0]			M_AXI_RVALID,
		output	wire	[NS-1:0]			M_AXI_RREADY,
		// }}}
		// }}}

        output  wire     [31:0]              GPIO_ADDR_OUT,
        // output  wire     [31:0]              GPIO_ADDR_OUT_1,
        // output  wire     [31:0]              GPIO_ADDR_OUT_2,
        // output  wire     [31:0]              GPIO_ADDR_OUT_3,
        // output  wire     [31:0]              GPIO_ADDR_OUT_4,
        // output  wire     [31:0]              GPIO_ADDR_OUT_5,
        // output  wire     [31:0]              GPIO_ADDR_OUT_6,
        // output  wire     [31:0]              GPIO_ADDR_OUT_7,
        // output  wire     [31:0]              GPIO_ADDR_OUT_8,
        input   wire     [31:0]              DEBUG_START_TURN,
        // input   wire     [31:0]              DEBUG_START_TURN_SUB,
        input   wire     [31:0]              DEBUG_INPUT_SIGNAL,
        input   wire     [31:0]              DEBUG_MEM_R_ADDR,
        // output  wire     [31:0]              DEBUG_MEM_R_DATA,
        // output  wire     [31:0]              DEBUG_MEM_R_DATA_1,
        // output  wire     [31:0]              DEBUG_MEM_R_DATA_2,
        // output  wire     [31:0]              DEBUG_MEM_R_DATA_3,
        // output  wire     [31:0]              DEBUG_MEM_R_TOTAL,
        // output  wire     [31:0]              DEBUG_MEM_R_WARN,
        output  wire     [31:0]              DEBUG_MEM_R_ERR,
		// output	wire	 [31:0]				 DEBUG_MEM_H_Y,
		// output	wire	 [31:0]				 DEBUG_MEM_H_UV,
        input   wire     [255:0]             Y_HASH_IN,
        input   wire     [255:0]             UV_HASH_IN,
        input   wire     [0:0]               IS_YUV_HASH_READY,
        output  wire     [0:0]               VERIFICATION_RESULT,
        output  wire     [0:0]               SKIP_FRAME_INDICATOR
	);

	// Local parameters, derived from those above
	// {{{
	// IW, AW, and DW, are short-hand abbreviations used locally.
	localparam	IW = C_AXI_ID_WIDTH;
	localparam	AW = C_AXI_ADDR_WIDTH;
	localparam	DW = C_AXI_DATA_WIDTH;
	// LGLINGER tells us how many bits we need for counting how long
	// to keep an udle channel open.
	localparam	LGLINGER = (OPT_LINGER>1) ? $clog2(OPT_LINGER+1) : 1;
	//
	localparam	LGNM = (NM>1) ? $clog2(NM) : 1;
	localparam	LGNS = (NS>1) ? $clog2(NS+1) : 1;
	//
	// In order to use indexes, and hence fully balanced mux trees, it helps
	// to make certain that we have a power of two based lookup.  NMFULL
	// is the number of masters in this lookup, with potentially some
	// unused extra ones.  NSFULL is defined similarly.
	localparam	NMFULL = (NM>1) ? (1<<LGNM) : 1;
	localparam	NSFULL = (NS>1) ? (1<<LGNS) : 2;
	//
	localparam [1:0] INTERCONNECT_ERROR = 2'b11;
	//
	// OPT_SKID_INPUT controls whether the input skid buffers register
	// their outputs or not.  If set, all skid buffers will cost one more
	// clock of latency.  It's not clear that there's a performance gain
	// to be had by setting this.
	localparam [0:0]	OPT_SKID_INPUT = 0;
	//
	// OPT_BUFFER_DECODER determines whether or not the outputs of the
	// address decoder will be buffered or not.  If buffered, there will
	// be an extra (registered) clock delay on each of the A* channels from
	// VALID to issue.
	localparam [0:0]	OPT_BUFFER_DECODER = 1;
	//
	// OPT_AWW controls whether or not a W* beat may be issued to a slave
	// at the same time as the first AW* beat gets sent to the slave.  Set
	// to 1'b1 for lower latency, at the potential cost of a greater
	// combinatorial path length
	localparam	OPT_AWW = 1'b1;

    // Myles: SHA256 local params
    localparam MODE_SHA_256   = 1'h1;
	localparam	[5:0]    SHA256_HASH_SIZE_IN_BYTES = SHA256_HASH_SIZE_IN_BITS / 8;
	localparam  [1:0]	 SHA256_NUM_OF_CYCLES_NEEDED_4_URAM_W = SHA256_HASH_SIZE_IN_BITS / MEM_DWIDTH;

	// frame parameters
	localparam PIXEL_SIZE_IN_BITS = PIXEL_Y_SIZE_IN_BITS + PIXEL_UV_SIZE_IN_BITS;
	localparam [31:0] FRAME_NUM_OF_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
	localparam [64:0] R_FRAME_Y_SIZE_IN_BITS = FRAME_NUM_OF_PIXELS * PIXEL_Y_SIZE_IN_BITS;
	localparam [31:0] R_FRAME_Y_SIZE_IN_BYTES = FRAME_NUM_OF_PIXELS * PIXEL_Y_SIZE_IN_BITS / 8;
	localparam [64:0] R_FRAME_UV_SIZE_IN_BITS = FRAME_NUM_OF_PIXELS * PIXEL_UV_SIZE_IN_BITS;
	localparam [31:0] R_FRAME_UV_SIZE_IN_BYTES = FRAME_NUM_OF_PIXELS * PIXEL_UV_SIZE_IN_BITS / 8;
	localparam R_FRAME_SIZE_IN_BITS = FRAME_NUM_OF_PIXELS * PIXEL_SIZE_IN_BITS;
	localparam R_FRAME_SIZE_IN_BYTES = R_FRAME_SIZE_IN_BITS / 8;
	localparam R_FRAME_UV_START_ADDR = R_FRAME_Y_START_ADDR + FRAME_NUM_OF_PIXELS;	// absolute addr
	localparam R_FRAME_END_ADDR = R_FRAME_Y_START_ADDR + R_FRAME_SIZE_IN_BYTES;
	localparam [31:0] R_FRAME_BLOCK_OFFSET = FRAME_WIDTH * ENCODER_BLOCK_HEIGHT * PIXEL_SIZE_IN_BITS / 8;	// size of each block in r_frame (in bytes)
	localparam NUM_OF_READ_EACH_BLOCK = R_FRAME_BLOCK_OFFSET * 8 / MEM_DWIDTH;
	localparam NUM_OF_BLOCKS_EACH_FRAME = FRAME_HEIGHT / ENCODER_BLOCK_HEIGHT;

	// reorder buffer parameters
	localparam [31:0] R_FRAME_ROB_UV_START_ADDR_IN_RAW = FRAME_WIDTH * ENCODER_BLOCK_HEIGHT;	// relative addr
	localparam [31:0] BLOCK_Y_SIZE_IN_BYTES = FRAME_WIDTH * ENCODER_BLOCK_HEIGHT * PIXEL_Y_SIZE_IN_BITS / 8;
	localparam [MEM_AWIDTH-1:0] BLOCK_UV_ROB_START_ADDR = BLOCK_Y_SIZE_IN_BYTES * 8 / MEM_DWIDTH;
	localparam [31:0] BLOCK_UV_SIZE_IN_BYTES = FRAME_WIDTH * ENCODER_BLOCK_HEIGHT * PIXEL_UV_SIZE_IN_BITS / 8;
	localparam [MEM_AWIDTH-1:0] BLOCK_UV_ROB_END_ADDR = BLOCK_UV_ROB_START_ADDR + BLOCK_UV_SIZE_IN_BYTES * 8 / MEM_DWIDTH;

	// rob e parameters
	localparam E_HASHER_DATA_READER_DEPTH = MAXBITSSTOREDONEBLOCK / MEM_DWIDTH;

	// outstanding write burst trasaction parameters
	localparam MAX_OUTSTANDING_WRITE_BURST_TRASACTIONS = 16;

	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Internal signal declarations and definitions
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	genvar	N,M;
	integer	iN, iM;

	reg	[NSFULL-1:0]	wrequest		[0:NM-1];
	reg	[NSFULL-1:0]	rrequest		[0:NM-1];
	reg	[NSFULL-1:0]	wrequested		[0:NM];
	reg	[NSFULL-1:0]	rrequested		[0:NM];
	reg	[NS:0]		wgrant			[0:NM-1];
	reg	[NS:0]		rgrant			[0:NM-1];
	reg	[NM-1:0]	mwgrant;
	reg	[NM-1:0]	mrgrant;
	reg	[NS-1:0]	swgrant;
	reg	[NS-1:0]	srgrant;

	// verilator lint_off UNUSED
	wire	[LGMAXBURST-1:0]	w_mawpending	[0:NM-1];
	wire	[LGMAXBURST-1:0]	wlasts_pending	[0:NM-1];
	wire	[LGMAXBURST-1:0]	w_mrpending	[0:NM-1];
	// verilator lint_on  UNUSED
	reg	[NM-1:0]		mwfull;
	reg	[NM-1:0]		mrfull;
	reg	[NM-1:0]		mwempty;
	reg	[NM-1:0]		mrempty;
	//
	wire	[LGNS-1:0]		mwindex	[0:NMFULL-1];
	wire	[LGNS-1:0]		mrindex	[0:NMFULL-1];
	wire	[LGNM-1:0]		swindex	[0:NSFULL-1];
	wire	[LGNM-1:0]		srindex	[0:NSFULL-1];

	wire	[NM-1:0]		wdata_expected;

	// The shadow buffers
	wire	[NMFULL-1:0]	m_awvalid, m_arvalid;
	wire	[NMFULL-1:0]	m_wvalid;
	wire	[NM-1:0]	dcd_awvalid, dcd_arvalid;

	wire	[C_AXI_ID_WIDTH-1:0]		m_awid		[0:NMFULL-1];
	wire	[C_AXI_ADDR_WIDTH-1:0]		m_awaddr	[0:NMFULL-1];
	wire	[7:0]				m_awlen		[0:NMFULL-1];
	wire	[2:0]				m_awsize	[0:NMFULL-1];
	wire	[1:0]				m_awburst	[0:NMFULL-1];
	wire	[NMFULL-1:0]			m_awlock;
	wire	[3:0]				m_awcache	[0:NMFULL-1];
	wire	[2:0]				m_awprot	[0:NMFULL-1];
	wire	[3:0]				m_awqos		[0:NMFULL-1];
	//
	wire	[C_AXI_DATA_WIDTH-1:0]		m_wdata		[0:NMFULL-1];
	wire	[C_AXI_DATA_WIDTH/8-1:0]	m_wstrb		[0:NMFULL-1];
	wire	[NMFULL-1:0]			m_wlast;

	wire	[C_AXI_ID_WIDTH-1:0]		m_arid		[0:NMFULL-1];
	wire	[C_AXI_ADDR_WIDTH-1:0]		m_araddr	[0:NMFULL-1];
	wire	[8-1:0]				m_arlen		[0:NMFULL-1];
	wire	[3-1:0]				m_arsize	[0:NMFULL-1];
	wire	[2-1:0]				m_arburst	[0:NMFULL-1];
	wire	[NMFULL-1:0]			m_arlock;
	wire	[4-1:0]				m_arcache	[0:NMFULL-1];
	wire	[2:0]				m_arprot	[0:NMFULL-1];
	wire	[3:0]				m_arqos		[0:NMFULL-1];
	//
	//
	reg	[NM-1:0]			berr_valid;
	reg	[IW-1:0]			berr_id		[0:NM-1];
	//
	reg	[NM-1:0]			rerr_none;
	reg	[NM-1:0]			rerr_last;
	reg	[8:0]				rerr_outstanding [0:NM-1];
	reg	[IW-1:0]			rerr_id		 [0:NM-1];

	wire	[NM-1:0]	skd_awvalid, skd_awstall;
	wire	[NM-1:0]	skd_arvalid, skd_arstall;
	wire	[IW-1:0]	skd_awid			[0:NM-1];
	wire	[AW-1:0]	skd_awaddr			[0:NM-1];
	wire	[8-1:0]		skd_awlen			[0:NM-1];
	wire	[3-1:0]		skd_awsize			[0:NM-1];
	wire	[2-1:0]		skd_awburst			[0:NM-1];
	wire	[NM-1:0]	skd_awlock;
	wire	[4-1:0]		skd_awcache			[0:NM-1];
	wire	[3-1:0]		skd_awprot			[0:NM-1];
	wire	[4-1:0]		skd_awqos			[0:NM-1];
	//
	wire	[IW-1:0]	skd_arid			[0:NM-1];
	wire	[AW-1:0]	skd_araddr			[0:NM-1];
	wire	[8-1:0]		skd_arlen			[0:NM-1];
	wire	[3-1:0]		skd_arsize			[0:NM-1];
	wire	[2-1:0]		skd_arburst			[0:NM-1];
	wire	[NM-1:0]	skd_arlock;
	wire	[4-1:0]		skd_arcache			[0:NM-1];
	wire	[3-1:0]		skd_arprot			[0:NM-1];
	wire	[4-1:0]		skd_arqos			[0:NM-1];

	// Verilator lint_off UNUSED
	reg	[NSFULL-1:0]	m_axi_awvalid;
	reg	[NSFULL-1:0]	m_axi_awready;
	reg	[IW-1:0]	m_axi_awid	[0:NSFULL-1];
	reg	[7:0]		m_axi_awlen	[0:NSFULL-1];

	reg	[NSFULL-1:0]	m_axi_wvalid;
	reg	[NSFULL-1:0]	m_axi_wready;
	reg	[NSFULL-1:0]	m_axi_bvalid;
	reg	[NSFULL-1:0]	m_axi_bready;
	// Verilator lint_on  UNUSED
	reg	[1:0]		m_axi_bresp	[0:NSFULL-1];
	reg	[IW-1:0]	m_axi_bid	[0:NSFULL-1];

	// Verilator lint_off UNUSED
	reg	[NSFULL-1:0]	m_axi_arvalid;
	reg	[7:0]		m_axi_arlen	[0:NSFULL-1];
	reg	[IW-1:0]	m_axi_arid	[0:NSFULL-1];
	reg	[NSFULL-1:0]	m_axi_arready;
	// Verilator lint_on  UNUSED
	reg	[NSFULL-1:0]	m_axi_rvalid;
	// Verilator lint_off UNUSED
	reg	[NSFULL-1:0]	m_axi_rready;
	// Verilator lint_on  UNUSED
	//
	reg	[IW-1:0]	m_axi_rid	[0:NSFULL-1];
	reg	[DW-1:0]	m_axi_rdata	[0:NSFULL-1];
	reg	[NSFULL-1:0]	m_axi_rlast;
	reg	[2-1:0]		m_axi_rresp	[0:NSFULL-1];

	reg	[NM-1:0]	slave_awaccepts;
	reg	[NM-1:0]	slave_waccepts;
	reg	[NM-1:0]	slave_raccepts;

	reg	[NM-1:0]	bskd_valid;
	reg	[NM-1:0]	rskd_valid, rskd_rlast;
	wire	[NM-1:0]	bskd_ready;
	wire	[NM-1:0]	rskd_ready;

	wire	[NMFULL-1:0]	write_qos_lockout,
				read_qos_lockout;

	reg	[NSFULL-1:0]	slave_awready, slave_wready, slave_arready;
	// }}}

    // Myles: Debug only parameters
    integer turn_to_start_logging;
    integer turn_to_start_logging_sub;
    reg [C_AXI_ADDR_WIDTH-1:0] last_m_wr_addr_reg;
    reg user_reset_signal;
    wire user_reset_wire;
    reg [3:0] outstanding_write_burst_transaction_counter_producer;
    reg [3:0] outstanding_write_burst_transaction_counter_consumer;
	reg [7:0] outstanding_write_burst_transaction_current_counter;
	reg [4:0] last_slice_switching_outstanding_burst_transaction_index_marker;
    reg [1:0] outstanding_write_burst_transaction_valid [MAX_OUTSTANDING_WRITE_BURST_TRASACTIONS-1:0];	// 0 for invalid; 1 for regular valid; 2 for new slice (except the first one)
    // reg [7:0] outstanding_write_burst_transaction_len [15:0];
    // reg [C_AXI_ADDR_WIDTH-1:0] outstanding_write_burst_transaction_addr [15:0];
    // reg [C_AXI_ADDR_WIDTH-1:0] first_value_addr_storage [MAXSTOREDFIRSTVALUE-1:0];
    // reg [C_AXI_DATA_WIDTH-1:0] first_value_storage [MAXSTOREDFIRSTVALUE-1:0];

    // verification of raw frames related
    reg skip_frame_indicator_reg;
    reg is_busy_verifying_r_frame;

	// rob 4 encoded data
	(* ram_style = "ultra" *)
    (* cascade_height = 16 *)
    reg [MEM_DWIDTH-1:0] mem_e[MEM_DDEPTH_4_E-1:0];        // Memory Declaration
    reg [MEM_DWIDTH-1:0] mem_e_r_data;
    reg is_mem_e_r_data_fresh;	// for debugging
    reg [MEM_DWIDTH-1:0] e_hasher_prepared_data [E_HASHER_DATA_READER_DEPTH-1:0];
	reg [MEM_AWIDTH_4_E-1:0] current_preparing_e_frame_data_index;
	reg [MEM_AWIDTH_4_E-1:0] i_for_e_hasher_prepared_data;
	wire mem_e_wea_wire;
	wire mem_e_en_wire;
	reg [MEM_AWIDTH_4_E-1:0] current_writing_rob_e_addr;
	reg [MEM_AWIDTH_4_E-1:0] next_slice_rob_e_start_addr;
	reg [MEM_AWIDTH_4_E-1:0] current_reading_rob_e_addr;
	reg [MEM_AWIDTH_4_E-1:0] current_reading_rob_e_addr_receipt;
	reg e_hasher_data_producer;
	reg e_hasher_data_consumer;
	integer e_hasher_is_not_catching_up_counter;
    reg [0:63] sha256_final_size_to_hash_e;   // Big Endian for SHA256
	reg is_slice_switcher_just_marked;
	reg is_switching_to_next_slice;
	reg is_switching_to_next_slice_receipt;
	reg [3:0] slice_switching_delay_counter;

    // reg [6:0] sha256_ring_buffer_r_ptr;
    // reg [6:0] sha256_ring_buffer_w_ptr;
    // reg [0:63] sha256_final_size_to_hash;   // Big Endian for SHA256
    // reg [0:63] sha256_final_size_to_hash_actual;   // Big Endian for SHA256
    // reg [31:0] sha256_debug_info [MAXSTOREDFIRSTVALUE*4-1:0];
    // reg [31:0] sha256_debug_info [31:0];
    reg is_too_many_outstanding_write_burst_transaction;
	reg hasher_e_is_not_catching_up;
    // integer is_too_many_outstanding_write_buffer;
    // integer sha256_debug_counter;
    // integer sha256_debug_counter_sub;
    // integer i_for_fvs;
    // integer i_for_fvs_sub;
    reg [4:0] i_for_outstanding_write_burst_transaction;
    reg [3:0] slice_counter_for_switching_frame;
    reg [31:0] current_writting_slice;
    wire is_new_aw_transaction_ready;
    wire is_new_w_transaction_ready;
    // reg [7:0] current_burst_transaction_remaining_write_counter;
    // integer burst_transaction_write_counter;

    // sha256 e related
    reg [31 : 0] sha256_block_reg [0 : 15];
    wire           sha256_core_ready;
    wire [255 : 0] sha256_core_digest;
    wire           sha256_core_digest_valid;
    wire [511 : 0] sha256_core_block;
    reg [255 : 0] sha256_digest_reg;
    reg sha256_digest_valid_reg;
    reg sha256_init_reg;
    wire sha256_w_buffer_almost_full_wire;
    wire sha256_stall_trigger_wire;
    reg sha256_next_reg;
    reg sha256_init_next_just_set_reg;
    integer sha256_init_next_reg_reset_counter;
    reg sha256_hash_step_reg;
    integer i;
    reg is_hashing_completed;
	wire sha256_e_rst_signal;	// for resetting sha256 cores between each frame
	reg [5:0] sha256_e_rst_counter;

	// sha256 r generic
	wire [0:63] sha256_r_final_size_4_y_be;
	wire [0:63] sha256_r_final_size_4_uv_be;
	wire sha256_r_rst_signal;	// for resetting sha256 cores between each frame
	reg [5:0] sha256_r_rst_counter;

	// sha256 r y
	reg [127:0] prepared_r_frame_y_data [3:0];
	reg [1:0] current_preparing_r_frame_y_data;	// we have to prepare 4*128 bits of data for each sha256 block, this is used to count that
	reg prepared_r_frame_y_data_producer;
	reg prepared_r_frame_y_data_consumer;
	reg [31:0] current_hashing_r_frame_y_total_size_in_bytes;
	reg [31 : 0] sha256_block_reg_y [0 : 15];
    wire           sha256_core_ready_y;
    wire [255 : 0] sha256_core_digest_y;
    wire           sha256_core_digest_valid_y;
    wire [511 : 0] sha256_core_block_y;
    reg [255 : 0] sha256_digest_reg_y;
    reg sha256_init_reg_y;
    wire sha256_w_buffer_almost_full_wire_y;
    wire sha256_stall_trigger_wire_y;
    reg sha256_next_reg_y;
    reg sha256_init_next_just_set_reg_y;
    integer sha256_init_next_reg_reset_counter_y;
    reg sha256_hash_step_reg_y;
    integer i_y;
    reg is_hashing_completed_y;
	reg is_hash_ready_to_be_written_y;	// for rst controller to set, which will then be read by hash rob
	reg sha256_error_reg_y;

	// sha256 r uv
	reg [127:0] prepared_r_frame_uv_data [3:0];
	reg [1:0] current_preparing_r_frame_uv_data;	// we have to prepare 4*128 bits of data for each sha256 block, this is used to count that
	reg prepared_r_frame_uv_data_producer;
	reg prepared_r_frame_uv_data_consumer;
	reg [31:0] current_hashing_r_frame_uv_total_size_in_bytes;
	reg [31 : 0] sha256_block_reg_uv [0 : 15];
    wire           sha256_core_ready_uv;
    wire [255 : 0] sha256_core_digest_uv;
    wire           sha256_core_digest_valid_uv;
    wire [511 : 0] sha256_core_block_uv;
    reg [255 : 0] sha256_digest_reg_uv;
    reg sha256_init_reg_uv;
    wire sha256_w_buffer_almost_full_wire_uv;
    wire sha256_stall_trigger_wire_uv;
    reg sha256_next_reg_uv;
    reg sha256_init_next_just_set_reg_uv;
    integer sha256_init_next_reg_reset_counter_uv;
    reg sha256_hash_step_reg_uv;
    integer i_uv;
    reg is_hashing_completed_uv;
	reg is_hash_ready_to_be_written_uv;	// for rst controller to set, which will then be read by hash rob
	reg sha256_error_reg_uv;

	// r hashes verification
	reg verification_result_reg;
	// reg [31:0] verification_error_reg;
    reg [31:0] fatal_verification_error_reg;

	// rob
	(* ram_style = "ultra" *)
    (* cascade_height = 16 *)
    reg [MEM_DWIDTH-1:0] mem[(2**MEM_AWIDTH)-1:0];        // Memory Declaration
    reg [MEM_DWIDTH-1:0] mem_r_data;
	wire mem_wea_wire;
	wire mem_en_wire;

	// untrusted mem generic
    reg [3:0] outstanding_raw_write_burst_transaction_counter_producer;
    reg [3:0] outstanding_raw_write_burst_transaction_counter_consumer;
	reg [7:0] outstanding_raw_write_burst_transaction_current_counter;
    reg [0:0] outstanding_raw_write_burst_transaction_valid [15:0];
    reg [7:0] outstanding_raw_write_burst_transaction_len [15:0];
    reg [C_AXI_ADDR_WIDTH-1:0] outstanding_raw_write_burst_transaction_addr [15:0];
    // reg [C_AXI_ADDR_WIDTH-1:0] outstanding_raw_write_burst_transaction_addr_debug [15:0];
    reg [4:0] i_for_raw_write_first_data;
	integer counter_for_raw_write_first_data;
    reg [31:0] raw_write_first_data [30:0];
    reg [4:0] i_for_outstanding_raw_write_burst_transaction;
    wire is_new_r_transaction_ready;
    reg is_too_many_outstanding_raw_write_burst_transaction;
	reg [31:0] current_r_reading_num_of_read_in_block; 	// counting number read in each block; for switching to next block
	reg [11:0] current_r_reading_num_of_blocks;	// counting current number of block; for addr translation and switching to next frame
	// reg [31:0] total_num_of_r_frames_read;	// debug
	reg current_writing_rob_section_index;	// two full rob
	wire [MEM_AWIDTH-1:0] current_reading_rob_addr;
	reg [MEM_AWIDTH-1:0] current_reading_rob_addr_receipt;	// to confirm that the reading is up-to-date
	reg	current_reading_rob_section_receipt;	// to confirm that the reading is up-to-date

	// helpers of hashing rob
	// note that the hashing only start if the very first reading is non-zero
	// Below are debug codes commented out
	// reg [31:0] generated_y_hash [15:0];
	// reg [31:0] generated_uv_hash [15:0];
	// reg [4:0] i_for_generated_hash;
    // reg done_debug_switch;
	// reg [4:0] debug_counter_4_generated_hash;
	wire current_hashing_rob_section_index;	// should always be opposite of current_writing_rob_section_index
	reg [MEM_AWIDTH-1:0] y_rob_hashing_pointer;
	reg [31:0] y_hashing_size_counter;	// for tracking when finished
	reg [MEM_AWIDTH-1:0] uv_rob_hashing_pointer;
	reg [31:0] uv_hashing_size_counter;	// for tracking when finished
	reg current_hashing_arbiter;	// 0 means y; 1 means uv
	// reg [31:0] total_num_of_r_frames_hashed;	// debug
	reg [11:0] current_r_hashing_num_of_blocks;
	reg hashers_are_not_catching_up_counter;

	// actual hashing
	reg [31:0] working_y_hash [15:0];
	reg [31:0] working_uv_hash [15:0];

    // Myles: assignment of SHA256 e related
    assign sha256_core_block = {sha256_block_reg[00], sha256_block_reg[01], sha256_block_reg[02], sha256_block_reg[03],
                            sha256_block_reg[04], sha256_block_reg[05], sha256_block_reg[06], sha256_block_reg[07],
                            sha256_block_reg[08], sha256_block_reg[09], sha256_block_reg[10], sha256_block_reg[11],
                            sha256_block_reg[12], sha256_block_reg[13], sha256_block_reg[14], sha256_block_reg[15]};

    assign user_reset_wire = !user_reset_signal;
    // assign sha256_w_buffer_almost_full_wire = (sha256_final_size_to_hash + (C_AXI_DATA_WIDTH * 8)) >= (sha256_final_size_to_hash_actual + (MAXSTOREDFIRSTVALUE * C_AXI_DATA_WIDTH));
    // assign sha256_w_buffer_almost_full_wire = (sha256_final_size_to_hash_e + (C_AXI_DATA_WIDTH * 8)) >= (sha256_final_size_to_hash_actual + (MEM_DDEPTH_4_E * C_AXI_DATA_WIDTH));
    assign sha256_stall_trigger_wire = (!sha256_core_ready) || sha256_init_reg || sha256_next_reg;
    assign is_new_aw_transaction_ready =  M_AXI_AWVALID && M_AXI_AWREADY;
    assign is_new_w_transaction_ready = M_AXI_WVALID && M_AXI_WREADY && M_AXI_WSTRB;
	assign mem_e_wea_wire = is_new_w_transaction_ready && outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_consumer];
	assign mem_e_en_wire = mem_e_wea_wire || (current_writing_rob_e_addr != current_reading_rob_e_addr);
	assign current_hashing_rob_section_index = !current_writing_rob_section_index;
	assign current_reading_rob_addr = current_hashing_arbiter ? uv_rob_hashing_pointer : y_rob_hashing_pointer;
	// assign current_reading_rob_addr = y_rob_hashing_pointer;

    // SHA256 e core
    sha256_core core(
                    .clk(S_AXI_ACLK),
                    .reset_n(user_reset_wire && (!sha256_e_rst_signal)),

                    .init(sha256_init_reg),
                    .next(sha256_next_reg),
                    .mode(MODE_SHA_256),

                    .block(sha256_core_block),

                    .ready(sha256_core_ready),

                    .digest(sha256_core_digest),
                    .digest_valid(sha256_core_digest_valid)
                   );

	// SHA256 r y core
    sha256_core core_y(
                    .clk(S_AXI_ACLK),
                    .reset_n(user_reset_wire && (!sha256_r_rst_signal)),

                    .init(sha256_init_reg_y),
                    .next(sha256_next_reg_y),
                    .mode(MODE_SHA_256),

                    .block(sha256_core_block_y),

                    .ready(sha256_core_ready_y),

                    .digest(sha256_core_digest_y),
                    .digest_valid(sha256_core_digest_valid_y)
                   );

	// SHA256 r uv core
    sha256_core core_uv(
                    .clk(S_AXI_ACLK),
                    .reset_n(user_reset_wire && (!sha256_r_rst_signal)),

                    .init(sha256_init_reg_uv),
                    .next(sha256_next_reg_uv),
                    .mode(MODE_SHA_256),

                    .block(sha256_core_block_uv),

                    .ready(sha256_core_ready_uv),

                    .digest(sha256_core_digest_uv),
                    .digest_valid(sha256_core_digest_valid_uv)
                   );

    assign is_new_r_transaction_ready = M_AXI_RVALID && M_AXI_RREADY;
	assign mem_wea_wire = is_new_r_transaction_ready && outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_consumer];
	// assign mem_en_wire = DEBUG_MEM_R_ADDR || mem_wea_wire || current_reading_rob_addr || (current_reading_rob_addr + 1);
	assign mem_en_wire = DEBUG_MEM_R_ADDR || mem_wea_wire || (current_r_hashing_num_of_blocks != current_r_reading_num_of_blocks);

	// sha256 r assignment
	assign sha256_r_final_size_4_y_be = {R_FRAME_Y_SIZE_IN_BITS[7:0], R_FRAME_Y_SIZE_IN_BITS[15:8], R_FRAME_Y_SIZE_IN_BITS[23:16], R_FRAME_Y_SIZE_IN_BITS[31:24], R_FRAME_Y_SIZE_IN_BITS[39:32], R_FRAME_Y_SIZE_IN_BITS[47:40], R_FRAME_Y_SIZE_IN_BITS[55:48], R_FRAME_Y_SIZE_IN_BITS[63:56]};
	assign sha256_r_final_size_4_uv_be = {R_FRAME_UV_SIZE_IN_BITS[7:0], R_FRAME_UV_SIZE_IN_BITS[15:8], R_FRAME_UV_SIZE_IN_BITS[23:16], R_FRAME_UV_SIZE_IN_BITS[31:24], R_FRAME_UV_SIZE_IN_BITS[39:32], R_FRAME_UV_SIZE_IN_BITS[47:40], R_FRAME_UV_SIZE_IN_BITS[55:48], R_FRAME_UV_SIZE_IN_BITS[63:56]};
	assign sha256_r_rst_signal = (sha256_r_rst_counter > 0);
	assign sha256_core_block_y = {sha256_block_reg_y[00], sha256_block_reg_y[01], sha256_block_reg_y[02], sha256_block_reg_y[03],
                            sha256_block_reg_y[04], sha256_block_reg_y[05], sha256_block_reg_y[06], sha256_block_reg_y[07],
                            sha256_block_reg_y[08], sha256_block_reg_y[09], sha256_block_reg_y[10], sha256_block_reg_y[11],
                            sha256_block_reg_y[12], sha256_block_reg_y[13], sha256_block_reg_y[14], sha256_block_reg_y[15]};
	assign sha256_core_block_uv = {sha256_block_reg_uv[00], sha256_block_reg_uv[01], sha256_block_reg_uv[02], sha256_block_reg_uv[03],
                            sha256_block_reg_uv[04], sha256_block_reg_uv[05], sha256_block_reg_uv[06], sha256_block_reg_uv[07],
                            sha256_block_reg_uv[08], sha256_block_reg_uv[09], sha256_block_reg_uv[10], sha256_block_reg_uv[11],
                            sha256_block_reg_uv[12], sha256_block_reg_uv[13], sha256_block_reg_uv[14], sha256_block_reg_uv[15]};
	assign sha256_stall_trigger_wire_y = (!sha256_core_ready_y) || sha256_init_reg_y || sha256_next_reg_y;
	assign sha256_stall_trigger_wire_uv = (!sha256_core_ready_uv) || sha256_init_reg_uv || sha256_next_reg_uv;

	// sha256 e assignment
	assign sha256_e_rst_signal = (sha256_e_rst_counter > 0);

	// r_hasher functions
	function [MEM_AWIDTH-1:0] raw_addr_to_rob_addr;
		input [C_AXI_ADDR_WIDTH-1:0] raw_addr;
		begin
			raw_addr_to_rob_addr = raw_addr / 16;
		end
  	endfunction

    // For r_hasher to listen new burst read transaction
	always @(posedge S_AXI_ACLK)
	begin
        if ((!S_AXI_ARESETN) || user_reset_signal)
        begin
            outstanding_raw_write_burst_transaction_counter_producer <= 0;
            for (i_for_outstanding_raw_write_burst_transaction = 0; i_for_outstanding_raw_write_burst_transaction < 16; i_for_outstanding_raw_write_burst_transaction = i_for_outstanding_raw_write_burst_transaction + 1)
            begin
                outstanding_raw_write_burst_transaction_valid[i_for_outstanding_raw_write_burst_transaction] <= 0;
                outstanding_raw_write_burst_transaction_len[i_for_outstanding_raw_write_burst_transaction] <= 0;
                outstanding_raw_write_burst_transaction_addr[i_for_outstanding_raw_write_burst_transaction] <= 0;
				// outstanding_raw_write_burst_transaction_addr_debug[i_for_outstanding_raw_write_burst_transaction] <= 0;
            end
            is_too_many_outstanding_raw_write_burst_transaction <= 0;
        end
        else if (M_AXI_ARREADY && M_AXI_ARVALID)
        begin
			// if (M_AXI_ARREADY && M_AXI_ARVALID)
            // begin
                if ((outstanding_raw_write_burst_transaction_counter_producer + 1) == outstanding_raw_write_burst_transaction_counter_consumer)
                    is_too_many_outstanding_raw_write_burst_transaction <= 1;
                // else
                // begin
                    outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_producer] <= ((M_AXI_ARADDR >= R_FRAME_Y_START_ADDR) && (M_AXI_ARADDR < R_FRAME_END_ADDR));
                    outstanding_raw_write_burst_transaction_len[outstanding_raw_write_burst_transaction_counter_producer] <= M_AXI_ARLEN;
                    outstanding_raw_write_burst_transaction_counter_producer <= outstanding_raw_write_burst_transaction_counter_producer + 1;
					// outstanding_raw_write_burst_transaction_addr_debug[outstanding_raw_write_burst_transaction_counter_producer] <= M_AXI_ARADDR;
					if (M_AXI_ARADDR < R_FRAME_UV_START_ADDR)
                    	outstanding_raw_write_burst_transaction_addr[outstanding_raw_write_burst_transaction_counter_producer] <= (M_AXI_ARADDR - R_FRAME_Y_START_ADDR) % BLOCK_Y_SIZE_IN_BYTES;
					else
						outstanding_raw_write_burst_transaction_addr[outstanding_raw_write_burst_transaction_counter_producer] <= ((M_AXI_ARADDR - R_FRAME_UV_START_ADDR) % BLOCK_UV_SIZE_IN_BYTES) + R_FRAME_ROB_UV_START_ADDR_IN_RAW;
                // end
            // end
        end
	end

    // For r_hasher to switch to next burst read transaction
    always @(posedge S_AXI_ACLK)
    begin
        if ((!S_AXI_ARESETN) || user_reset_signal)
        begin
            outstanding_raw_write_burst_transaction_counter_consumer <= 0;
			outstanding_raw_write_burst_transaction_current_counter <= 0;
        end
        else if (is_new_r_transaction_ready)
        begin
			if (M_AXI_RLAST)
			begin
            	outstanding_raw_write_burst_transaction_counter_consumer <= outstanding_raw_write_burst_transaction_counter_consumer + 1;
				outstanding_raw_write_burst_transaction_current_counter <= 0;
			end
			else
				outstanding_raw_write_burst_transaction_current_counter <= outstanding_raw_write_burst_transaction_current_counter + 1;
        end
    end
	
    // rob producer
	always @(posedge S_AXI_ACLK)
    begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			mem_r_data <= 0;
			current_r_reading_num_of_read_in_block <= 0;
			current_r_reading_num_of_blocks <= 0;
			// total_num_of_r_frames_read <= 0;
			current_writing_rob_section_index <= 0;
			// counter_for_raw_write_first_data <= 0;
			current_reading_rob_addr_receipt <= NUM_OF_READ_EACH_BLOCK;
			// current_reading_rob_section_receipt <= 0;
			hashers_are_not_catching_up_counter <= 0;
			// for (i_for_raw_write_first_data = 0; i_for_raw_write_first_data < 16; i_for_raw_write_first_data = i_for_raw_write_first_data + 1)
            // begin
            //     raw_write_first_data[i_for_raw_write_first_data] <= 0;
            //     raw_write_first_data[i_for_raw_write_first_data+15] <= 0;
            // end
		end
		else if(mem_en_wire) 
		begin
			// do debug (no limit)
			// if (mem_wea_wire && (counter_for_raw_write_first_data < 31) && (outstanding_raw_write_burst_transaction_current_counter == 0) && (outstanding_raw_write_burst_transaction_addr_debug[outstanding_raw_write_burst_transaction_counter_consumer] == R_FRAME_Y_START_ADDR))
			// begin
			// 	raw_write_first_data[counter_for_raw_write_first_data] <= M_AXI_RDATA;
			// 	counter_for_raw_write_first_data <= counter_for_raw_write_first_data + 1;
			// end

			if(mem_wea_wire)
			begin
				// do write
				mem[(current_writing_rob_section_index * NUM_OF_READ_EACH_BLOCK) + raw_addr_to_rob_addr(outstanding_raw_write_burst_transaction_addr[outstanding_raw_write_burst_transaction_counter_consumer]) + outstanding_raw_write_burst_transaction_current_counter] <= M_AXI_RDATA;

				// do counter
				if ((current_r_reading_num_of_read_in_block + 1) == NUM_OF_READ_EACH_BLOCK)
				begin
					current_r_reading_num_of_read_in_block <= 0;

					// check if hashers have caught up
					if (current_r_reading_num_of_blocks != current_r_hashing_num_of_blocks)
						hashers_are_not_catching_up_counter <= 1;

					// switch to next block counter (and potentially frame)
					if ((current_r_reading_num_of_blocks + 1) == NUM_OF_BLOCKS_EACH_FRAME)
					begin
						current_r_reading_num_of_blocks <= 0;
						// total_num_of_r_frames_read <= total_num_of_r_frames_read + 1;
					end
					else
						current_r_reading_num_of_blocks <= current_r_reading_num_of_blocks + 1;

					// switch to next mem section
					current_writing_rob_section_index <= current_writing_rob_section_index + 1;
				end
				else
					current_r_reading_num_of_read_in_block <= current_r_reading_num_of_read_in_block + 1;
			end
			
			// do read
			if (current_r_hashing_num_of_blocks != current_r_reading_num_of_blocks)
			begin
				mem_r_data <= mem[(current_hashing_rob_section_index * NUM_OF_READ_EACH_BLOCK) + current_reading_rob_addr];
				current_reading_rob_addr_receipt <= current_reading_rob_addr;
				// current_reading_rob_section_receipt <= current_hashing_rob_section_index;
			end
			else
				current_reading_rob_addr_receipt <= NUM_OF_READ_EACH_BLOCK;	// invalidate the read
		end
    end

	// rob consumer
	// preparing data for hashing (for both Y and UV)
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			current_hashing_arbiter <= 0;
			y_rob_hashing_pointer <= 0;
			uv_rob_hashing_pointer <= BLOCK_UV_ROB_START_ADDR;
			prepared_r_frame_y_data[0] <= 0;
			prepared_r_frame_y_data[1] <= 0;
			prepared_r_frame_y_data[2] <= 0;
			prepared_r_frame_y_data[3] <= 0;
			prepared_r_frame_uv_data[0] <= 0;
			prepared_r_frame_uv_data[1] <= 0;
			prepared_r_frame_uv_data[2] <= 0;
			prepared_r_frame_uv_data[3] <= 0;
			current_preparing_r_frame_y_data <= 0;
			current_preparing_r_frame_uv_data <= 0;
			prepared_r_frame_y_data_producer <= 0;
			prepared_r_frame_uv_data_producer <= 0;
			current_r_hashing_num_of_blocks <= 0;
		end
		// check if we can prepare the data for hashing
		else if (current_r_hashing_num_of_blocks != current_r_reading_num_of_blocks)
		begin
			// check if all y and uv data are prepared in a block
			if ((y_rob_hashing_pointer == BLOCK_UV_ROB_START_ADDR) && (uv_rob_hashing_pointer == BLOCK_UV_ROB_END_ADDR))
			begin
				y_rob_hashing_pointer <= 0;
				uv_rob_hashing_pointer <= BLOCK_UV_ROB_START_ADDR;
				current_hashing_arbiter <= 0;

				current_r_hashing_num_of_blocks <= current_r_hashing_num_of_blocks + 1;
				if ((current_r_hashing_num_of_blocks + 1) == NUM_OF_BLOCKS_EACH_FRAME)
					current_r_hashing_num_of_blocks <= 0;
			end
			// prepare data for hashing r y
			// else if ((!current_hashing_arbiter) && (prepared_r_frame_y_data_producer == prepared_r_frame_y_data_consumer) && (y_rob_hashing_pointer == current_reading_rob_addr_receipt) && (current_hashing_rob_section_index == current_reading_rob_section_receipt))
			else if ((current_hashing_arbiter == 0) && (prepared_r_frame_y_data_producer == prepared_r_frame_y_data_consumer) && (y_rob_hashing_pointer == current_reading_rob_addr_receipt))
			begin
				// prepare the data
				prepared_r_frame_y_data[current_preparing_r_frame_y_data] <= mem_r_data;

				// update y rob pointer
				y_rob_hashing_pointer <= y_rob_hashing_pointer + 1;

				// check if we have fully prepared the data
				if (current_preparing_r_frame_y_data == 3)
				begin
					current_preparing_r_frame_y_data <= 0;

					// update sha256 prepared data consumer
					prepared_r_frame_y_data_producer <= prepared_r_frame_y_data_producer + 1;

					// switch arbiter if the counterpart is not finished yet
					if (uv_rob_hashing_pointer < BLOCK_UV_ROB_END_ADDR)
						current_hashing_arbiter <= 1;
				end
				current_preparing_r_frame_y_data <= current_preparing_r_frame_y_data + 1;
			end
			// prepare data for hashing r uv
			// else if (current_hashing_arbiter && (prepared_r_frame_uv_data_producer == prepared_r_frame_uv_data_consumer) && (uv_rob_hashing_pointer == current_reading_rob_addr_receipt) && (current_hashing_rob_section_index == current_reading_rob_section_receipt))
			else if ((current_hashing_arbiter == 1) && (prepared_r_frame_uv_data_producer == prepared_r_frame_uv_data_consumer) && (uv_rob_hashing_pointer == current_reading_rob_addr_receipt))
			begin
				// prepare the data
				prepared_r_frame_uv_data[current_preparing_r_frame_uv_data] <= mem_r_data;

				// update y rob pointer
				uv_rob_hashing_pointer <= uv_rob_hashing_pointer + 1;

				// check if we have fully prepared the data
				if (current_preparing_r_frame_uv_data == 3)
				begin
					current_preparing_r_frame_uv_data <= 0;

					// update sha256 prepared data consumer
					prepared_r_frame_uv_data_producer <= prepared_r_frame_uv_data_producer + 1;

					// switch arbiter if the counterpart is not finished yet
					if (y_rob_hashing_pointer < BLOCK_UV_ROB_START_ADDR)
						current_hashing_arbiter <= 0;
				end
				current_preparing_r_frame_uv_data <= current_preparing_r_frame_uv_data + 1;
			end

		end
	end
	
	// run sha256 for y
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal || sha256_r_rst_signal)
		begin
			for (i_y = 0 ; i_y < 16 ; i_y = i_y + 1)
				sha256_block_reg_y[i_y] <= 32'h0;
			sha256_init_reg_y         <= 0;
			sha256_next_reg_y         <= 0;
			sha256_init_next_just_set_reg_y <= 0;
			sha256_init_next_reg_reset_counter_y <= 0;
			sha256_hash_step_reg_y <= 0;
			is_hashing_completed_y <= 0;
			prepared_r_frame_y_data_consumer <= prepared_r_frame_y_data_producer;
			current_hashing_r_frame_y_total_size_in_bytes <= 0;
            sha256_error_reg_y <= 0;
		end
		else
		begin

			// automatic init/next reset (to prevent recalculation)
			if (sha256_init_reg_y || sha256_next_reg_y)
			begin
				if ((sha256_init_next_reg_reset_counter_y == 4) && (!sha256_init_next_just_set_reg_y))
				begin
					sha256_init_reg_y <= 0;
					sha256_next_reg_y <= 0;
				end
				
				if (sha256_init_next_just_set_reg_y)
				begin
					sha256_init_next_reg_reset_counter_y <= 0;
					sha256_init_next_just_set_reg_y <= 0;
				end
				else
					sha256_init_next_reg_reset_counter_y <= sha256_init_next_reg_reset_counter_y + 1;
			end

			// Read prepared data
			if (!sha256_stall_trigger_wire_y)
			begin
				if ((prepared_r_frame_y_data_producer != prepared_r_frame_y_data_consumer) && (current_hashing_r_frame_y_total_size_in_bytes < R_FRAME_Y_SIZE_IN_BYTES))
				begin
					sha256_block_reg_y[0] <= prepared_r_frame_y_data[0][31:0];
					sha256_block_reg_y[1] <= prepared_r_frame_y_data[0][63:32];
					sha256_block_reg_y[2] <= prepared_r_frame_y_data[0][95:64];
					sha256_block_reg_y[3] <= prepared_r_frame_y_data[0][127:96];
					sha256_block_reg_y[4] <= prepared_r_frame_y_data[1][31:0];
					sha256_block_reg_y[5] <= prepared_r_frame_y_data[1][63:32];
					sha256_block_reg_y[6] <= prepared_r_frame_y_data[1][95:64];
					sha256_block_reg_y[7] <= prepared_r_frame_y_data[1][127:96];
					sha256_block_reg_y[8] <= prepared_r_frame_y_data[2][31:0];
					sha256_block_reg_y[9] <= prepared_r_frame_y_data[2][63:32];
					sha256_block_reg_y[10] <= prepared_r_frame_y_data[2][95:64];
					sha256_block_reg_y[11] <= prepared_r_frame_y_data[2][127:96];
					sha256_block_reg_y[12] <= prepared_r_frame_y_data[3][31:0];
					sha256_block_reg_y[13] <= prepared_r_frame_y_data[3][63:32];
					sha256_block_reg_y[14] <= prepared_r_frame_y_data[3][95:64];
					sha256_block_reg_y[15] <= prepared_r_frame_y_data[3][127:96];

					// confirm that prepared data is consumed
					prepared_r_frame_y_data_consumer <= prepared_r_frame_y_data_consumer + 1;
					
					case (sha256_hash_step_reg_y)
						0: sha256_init_reg_y <= 1;
						default: sha256_next_reg_y <= 1;
					endcase
					sha256_init_next_just_set_reg_y <= 1;

					sha256_hash_step_reg_y <= 1;

					current_hashing_r_frame_y_total_size_in_bytes <= current_hashing_r_frame_y_total_size_in_bytes + SHA256_BLOCK_SIZE_IN_BYTES;
				end
				else if ((current_hashing_r_frame_y_total_size_in_bytes >= R_FRAME_Y_SIZE_IN_BYTES) && (!is_hashing_completed_y))    // Myles: done with a frame
				begin

					// debug: error checking
					if (current_hashing_r_frame_y_total_size_in_bytes > R_FRAME_Y_SIZE_IN_BYTES)
						sha256_error_reg_y <= 1;
					else
					begin
						// prepare last block data
						for (i_y = 0 ; i_y < 16 ; i_y = i_y + 1)
							sha256_block_reg_y[i_y] <= 32'h0;
						sha256_block_reg_y[0] <= 32'h80000000;
						sha256_block_reg_y[14] <= sha256_r_final_size_4_y_be[0:31];
						sha256_block_reg_y[15] <= sha256_r_final_size_4_y_be[32:63];
					end

					sha256_next_reg_y <= 1;
					sha256_init_next_just_set_reg_y <= 1;
					is_hashing_completed_y <= 1;
				end
			end
		end
	end
	
	// run sha256 for uv
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal || sha256_r_rst_signal)
		begin
			for (i_uv = 0 ; i_uv < 16 ; i_uv = i_uv + 1)
				sha256_block_reg_uv[i_uv] <= 32'h0;
			sha256_init_reg_uv         <= 0;
			sha256_next_reg_uv         <= 0;
			sha256_init_next_just_set_reg_uv <= 0;
			sha256_init_next_reg_reset_counter_uv <= 0;
			sha256_hash_step_reg_uv <= 0;
			is_hashing_completed_uv <= 0;
			prepared_r_frame_uv_data_consumer <= prepared_r_frame_uv_data_producer;
			current_hashing_r_frame_uv_total_size_in_bytes <= 0;
            sha256_error_reg_uv <= 0;
		end
		else
		begin

			// automatic init/next reset (to prevent recalculation)
			if (sha256_init_reg_uv || sha256_next_reg_uv)
			begin
				if ((sha256_init_next_reg_reset_counter_uv == 4) && (!sha256_init_next_just_set_reg_uv))
				begin
					sha256_init_reg_uv <= 0;
					sha256_next_reg_uv <= 0;
				end
				
				if (sha256_init_next_just_set_reg_uv)
				begin
					sha256_init_next_reg_reset_counter_uv <= 0;
					sha256_init_next_just_set_reg_uv <= 0;
				end
				else
					sha256_init_next_reg_reset_counter_uv <= sha256_init_next_reg_reset_counter_uv + 1;
			end

			// Read prepared data
			if (!sha256_stall_trigger_wire_uv)
			begin
				if ((prepared_r_frame_uv_data_producer != prepared_r_frame_uv_data_consumer) && (current_hashing_r_frame_uv_total_size_in_bytes < R_FRAME_UV_SIZE_IN_BYTES))
				begin
					sha256_block_reg_uv[0] <= prepared_r_frame_uv_data[0][31:0];
					sha256_block_reg_uv[1] <= prepared_r_frame_uv_data[0][63:32];
					sha256_block_reg_uv[2] <= prepared_r_frame_uv_data[0][95:64];
					sha256_block_reg_uv[3] <= prepared_r_frame_uv_data[0][127:96];
					sha256_block_reg_uv[4] <= prepared_r_frame_uv_data[1][31:0];
					sha256_block_reg_uv[5] <= prepared_r_frame_uv_data[1][63:32];
					sha256_block_reg_uv[6] <= prepared_r_frame_uv_data[1][95:64];
					sha256_block_reg_uv[7] <= prepared_r_frame_uv_data[1][127:96];
					sha256_block_reg_uv[8] <= prepared_r_frame_uv_data[2][31:0];
					sha256_block_reg_uv[9] <= prepared_r_frame_uv_data[2][63:32];
					sha256_block_reg_uv[10] <= prepared_r_frame_uv_data[2][95:64];
					sha256_block_reg_uv[11] <= prepared_r_frame_uv_data[2][127:96];
					sha256_block_reg_uv[12] <= prepared_r_frame_uv_data[3][31:0];
					sha256_block_reg_uv[13] <= prepared_r_frame_uv_data[3][63:32];
					sha256_block_reg_uv[14] <= prepared_r_frame_uv_data[3][95:64];
					sha256_block_reg_uv[15] <= prepared_r_frame_uv_data[3][127:96];

					// confirm that prepared data is consumed
					prepared_r_frame_uv_data_consumer <= prepared_r_frame_uv_data_consumer + 1;
					
					case (sha256_hash_step_reg_uv)
						0: sha256_init_reg_uv <= 1;
						default: sha256_next_reg_uv <= 1;
					endcase
					sha256_init_next_just_set_reg_uv <= 1;

					sha256_hash_step_reg_uv <= 1;

					current_hashing_r_frame_uv_total_size_in_bytes <= current_hashing_r_frame_uv_total_size_in_bytes + SHA256_BLOCK_SIZE_IN_BYTES;
				end
				else if ((current_hashing_r_frame_uv_total_size_in_bytes >= R_FRAME_UV_SIZE_IN_BYTES) && (!is_hashing_completed_uv))    // Myles: done with a frame
				begin

					// debug: error checking
					if (current_hashing_r_frame_uv_total_size_in_bytes > R_FRAME_UV_SIZE_IN_BYTES)
						sha256_error_reg_uv <= 1;
					else
					begin
						// prepare last block data
						for (i_uv = 0 ; i_uv < 16 ; i_uv = i_uv + 1)
							sha256_block_reg_uv[i_uv] <= 32'h0;
						sha256_block_reg_uv[0] <= 32'h80000000;
						sha256_block_reg_uv[14] <= sha256_r_final_size_4_uv_be[0:31];
						sha256_block_reg_uv[15] <= sha256_r_final_size_4_uv_be[32:63];
					end

					sha256_next_reg_uv <= 1;
					sha256_init_next_just_set_reg_uv <= 1;
					is_hashing_completed_uv <= 1;
				end
			end
		end
	end

	// read final hash of sha256 r
	// control rst of sha256 r
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			sha256_r_rst_counter <= 0;
			sha256_digest_reg_y       <= 256'h0;
			sha256_digest_reg_uv       <= 256'h0;
			is_hash_ready_to_be_written_y <= 0;
			is_hash_ready_to_be_written_uv <= 0;
            // fatal_verification_error_reg <= 0;
		end
		else if (sha256_r_rst_signal)
		begin
			is_hash_ready_to_be_written_y <= 0;
			is_hash_ready_to_be_written_uv <= 0;
			sha256_r_rst_counter <= sha256_r_rst_counter - 1;
		end
		else if ((!is_busy_verifying_r_frame) && is_hashing_completed_y && is_hashing_completed_uv && (!sha256_stall_trigger_wire_y) && (!sha256_stall_trigger_wire_uv) && sha256_core_digest_valid_y && sha256_core_digest_valid_uv && (!sha256_r_rst_counter))
		begin
            // detect fatal error
            // if (is_busy_verifying_r_frame && (fatal_verification_error_reg == 0))
            //     fatal_verification_error_reg <= total_num_of_r_frames_hashed;

			// write hash to register
			sha256_digest_reg_y <= sha256_core_digest_y;
			sha256_digest_reg_uv <= sha256_core_digest_uv;

			// add one frame
			// total_num_of_r_frames_hashed <= total_num_of_r_frames_hashed + 1;

			// init rst
			sha256_r_rst_counter <= SHA256_RST_NUM_OF_CLOCKS;

			// set hash ready to be verified
			is_hash_ready_to_be_written_y <= 1;
			is_hash_ready_to_be_written_uv <= 1;
		end
	end

    // hash verifier
    always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
            verification_result_reg <= 0;
            // verification_error_reg <= 0;
            skip_frame_indicator_reg <= 0;
            is_busy_verifying_r_frame <= 0;
		end
        else if (skip_frame_indicator_reg || (is_hash_ready_to_be_written_y && is_hash_ready_to_be_written_uv))
        begin
            is_busy_verifying_r_frame <= 1;
            // verify hash
            if (IS_YUV_HASH_READY)
            begin
                if ((sha256_digest_reg_y == Y_HASH_IN) && (sha256_digest_reg_uv == UV_HASH_IN))
                begin
                    verification_result_reg <= 1;
                    // verification_error_reg <= 0;
                    skip_frame_indicator_reg <= 0;
                end
                // else if (verification_error_reg == 0)
				else
                begin
                    skip_frame_indicator_reg <= 1;
                    // verification_error_reg <= total_num_of_r_frames_hashed;
                end
            end
        end
        else
        begin
            is_busy_verifying_r_frame <= 0;
            skip_frame_indicator_reg <= 0;
            verification_result_reg <= 0;
        end
    end

	// hash debugger
	// always @(posedge S_AXI_ACLK)
	// begin
	// 	if ((!S_AXI_ARESETN) || user_reset_signal)
	// 	begin
	// 		for (i_for_generated_hash = 0; i_for_generated_hash < 16; i_for_generated_hash = i_for_generated_hash + 1)
	// 		begin
	// 			generated_y_hash[i_for_generated_hash] <= 0;
	// 			generated_uv_hash[i_for_generated_hash] <= 0;
	// 		end
	// 		debug_counter_4_generated_hash <= 0;
    //         done_debug_switch <= 0;
	// 	end
	// 	else if (is_hash_ready_to_be_written_y && is_hash_ready_to_be_written_uv && (debug_counter_4_generated_hash < 16))
	// 	begin
	// 		generated_y_hash[debug_counter_4_generated_hash] <= sha256_digest_reg_y;
    //         generated_uv_hash[debug_counter_4_generated_hash] <= sha256_digest_reg_uv;

    //         if ((debug_counter_4_generated_hash == 15) && (!done_debug_switch))
    //             debug_counter_4_generated_hash <= 0;
    //         else
    //             debug_counter_4_generated_hash <= debug_counter_4_generated_hash + 1;

    //         if (verification_error_reg != 0)
    //             done_debug_switch <= 1;
	// 	end
	// end

	// m_axi_* convenience signals (write side)
	// {{{
	always @(*)
	begin
		m_axi_awvalid = -1;
		m_axi_awready = -1;
		m_axi_wvalid = -1;
		m_axi_wready = -1;
		m_axi_bvalid = 0;
		m_axi_bready = -1;

		m_axi_awvalid[NS-1:0] = M_AXI_AWVALID;
		m_axi_awready[NS-1:0] = M_AXI_AWREADY;
		m_axi_wvalid[NS-1:0]  = M_AXI_WVALID;
		m_axi_wready[NS-1:0]  = M_AXI_WREADY;
		m_axi_bvalid[NS-1:0]  = M_AXI_BVALID;
		m_axi_bready[NS-1:0]  = M_AXI_BREADY;

		for(iM=0; iM<NS; iM=iM+1)
		begin
			m_axi_awid[iM]   = M_AXI_AWID[   iM*IW +: IW];
			m_axi_awlen[iM]  = M_AXI_AWLEN[  iM* 8 +:  8];

			m_axi_bid[iM]   = M_AXI_BID[iM* IW +:  IW];
			m_axi_bresp[iM] = M_AXI_BRESP[iM* 2 +:  2];

			m_axi_rid[iM]   = M_AXI_RID[  iM*IW +: IW];
			m_axi_rdata[iM] = M_AXI_RDATA[iM*DW +: DW];
			m_axi_rresp[iM] = M_AXI_RRESP[iM* 2 +:  2];
			m_axi_rlast[iM] = M_AXI_RLAST[iM];
		end

		for(iM=NS; iM<NSFULL; iM=iM+1)
		begin
			m_axi_awid[iM]   = 0;
			m_axi_awlen[iM]  = 0;

			m_axi_bresp[iM] = INTERCONNECT_ERROR;
			m_axi_bid[iM]   = 0;

			m_axi_rid[iM]   = 0;
			m_axi_rdata[iM] = 0;
			m_axi_rresp[iM] = INTERCONNECT_ERROR;
			m_axi_rlast[iM] = 1;
		end
	end
	// }}}

	// m_axi_* convenience signals (read side)
	// {{{
	always @(*)
	begin
		m_axi_arvalid = 0;
		m_axi_arready = 0;
		m_axi_rvalid = 0;
		m_axi_rready = 0;
		for(iM=0; iM<NS; iM=iM+1)
		begin
			m_axi_arlen[iM] = M_AXI_ARLEN[iM* 8 +:  8];
			m_axi_arid[iM]  = M_AXI_ARID[ iM*IW +: IW];
		end
		for(iM=NS; iM<NSFULL; iM=iM+1)
		begin
			m_axi_arlen[iM] = 0;
			m_axi_arid[iM]  = 0;
		end

		m_axi_arvalid[NS-1:0] = M_AXI_ARVALID;
		m_axi_arready[NS-1:0] = M_AXI_ARREADY;
		m_axi_rvalid[NS-1:0]  = M_AXI_RVALID;
		m_axi_rready[NS-1:0]  = M_AXI_RREADY;
	end
	// }}}

	// slave_*ready convenience signals
	// {{{
	always @(*)
	begin
		// These are designed to keep us from doing things like
		// m_axi_*[m?index[N]] && m_axi_*[m?index[N]] && .. etc
		//
		// First, we'll set bits for all slaves--to include those that
		// are undefined (but required by our static analysis tools).
		slave_awready = -1;
		slave_wready  = -1;
		slave_arready = -1;
		//
		// Here we do all of the combinatoric calculations, so the
		// master only needs to reference one bit of this signal
		slave_awready[NS-1:0] = (~M_AXI_AWVALID | M_AXI_AWREADY);
		// slave_awready[NS-1:0] = (~M_AXI_AWVALID | M_AXI_AWREADY) && (!sha256_w_buffer_almost_full_wire);
		slave_wready[NS-1:0]  = (~M_AXI_WVALID | M_AXI_WREADY);
		// slave_wready[NS-1:0]  = (~M_AXI_WVALID | M_AXI_WREADY) && (!sha256_w_buffer_almost_full_wire);
		slave_arready[NS-1:0] = (~M_AXI_ARVALID | M_AXI_ARREADY);
	end
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Process our incoming signals: AW*, W*, and AR*
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	generate for(N=0; N<NM; N=N+1)
	begin : W1_DECODE_WRITE_REQUEST
	// {{{
		wire	[NS:0]	wdecode;

		// awskid, the skidbuffer for the incoming AW* channel
		// {{{
		skidbuffer #(
			// {{{
			.DW(IW+AW+8+3+2+1+4+3+4),
			.OPT_OUTREG(OPT_SKID_INPUT)
			// }}}
		) awskid(
			// {{{
			S_AXI_ACLK, !S_AXI_ARESETN,
			S_AXI_AWVALID[N], S_AXI_AWREADY[N],
			{ S_AXI_AWID[N*IW +: IW], S_AXI_AWADDR[N*AW +: AW],
			  S_AXI_AWLEN[N*8 +: 8], S_AXI_AWSIZE[N*3 +: 3],
			  S_AXI_AWBURST[N*2 +: 2], S_AXI_AWLOCK[N],
			  S_AXI_AWCACHE[N*4 +: 4], S_AXI_AWPROT[N*3 +: 3],
			  S_AXI_AWQOS[N*4 +: 4] },
			skd_awvalid[N], !skd_awstall[N],
			// skd_awvalid[N], (!skd_awstall[N]) && (!sha256_w_buffer_almost_full_wire),
			{ skd_awid[N], skd_awaddr[N], skd_awlen[N],
			  skd_awsize[N], skd_awburst[N], skd_awlock[N],
			  skd_awcache[N], skd_awprot[N], skd_awqos[N] }
			// }}}
		);
		// }}}

		// wraddr, decode the write channel's address request to a
		// particular slave index
		// {{{
		addrdecode #(
			// {{{
			.AW(AW), .DW(IW+8+3+2+1+4+3+4), .NS(NS),
			.SLAVE_ADDR(SLAVE_ADDR),
			.SLAVE_MASK(SLAVE_MASK),
			.OPT_REGISTERED(OPT_BUFFER_DECODER)
			// }}}
		) wraddr(
			// {{{
			.i_clk(S_AXI_ACLK), .i_reset(!S_AXI_ARESETN),
			.i_valid(skd_awvalid[N]), .o_stall(skd_awstall[N]),
				.i_addr(skd_awaddr[N]), .i_data({ skd_awid[N],
				skd_awlen[N], skd_awsize[N], skd_awburst[N],
				skd_awlock[N], skd_awcache[N], skd_awprot[N],
				skd_awqos[N] }),
			.o_valid(dcd_awvalid[N]),
				.i_stall(!dcd_awvalid[N]||!slave_awaccepts[N]),
				.o_decode(wdecode), .o_addr(m_awaddr[N]),
				.o_data({ m_awid[N], m_awlen[N], m_awsize[N],
				  m_awburst[N], m_awlock[N], m_awcache[N],
				  m_awprot[N], m_awqos[N]})
			// }}}
		);
		// }}}

		// wskid, the skid buffer for the incoming W* channel
		// {{{
		skidbuffer #(
			// {{{
			.DW(DW+DW/8+1),
			.OPT_OUTREG(OPT_SKID_INPUT || OPT_BUFFER_DECODER)
			// }}}
		) wskid(
			// {{{
			S_AXI_ACLK, !S_AXI_ARESETN,
			S_AXI_WVALID[N], S_AXI_WREADY[N],
			{ S_AXI_WDATA[N*DW +: DW], S_AXI_WSTRB[N*DW/8 +: DW/8],
			  S_AXI_WLAST[N] },
			m_wvalid[N], slave_waccepts[N],
			// m_wvalid[N], slave_waccepts[N] && (!sha256_w_buffer_almost_full_wire),
			{ m_wdata[N], m_wstrb[N], m_wlast[N] }
			// }}}
		);
		// }}}

		// slave_awaccepts
		// {{{
		always @(*)
		begin
			slave_awaccepts[N] = 1'b1;

			// Cannot accept/forward a packet without a bus grant
			// This handles whether or not write data is still
			// pending.
			if (!mwgrant[N])
				slave_awaccepts[N] = 1'b0;
			if (write_qos_lockout[N])
				slave_awaccepts[N] = 1'b0;
			if (mwfull[N])
				slave_awaccepts[N] = 1'b0;
			// Don't accept a packet unless its to the same slave
			// the grant is issued for
			if (!wrequest[N][mwindex[N]])
				slave_awaccepts[N] = 1'b0;
			if (!wgrant[N][NS])
			begin
				if (!slave_awready[mwindex[N]])
					slave_awaccepts[N] = 1'b0;
			end else if (berr_valid[N] && !bskd_ready[N])
			begin
				// Can't accept an write address channel request
				// for the no-address-mapped channel if the
				// B* channel is stalled, lest we lose the ID
				// of the transaction
				//
				// !berr_valid[N] => we have to accept more
				//	write data before we can issue BVALID
				slave_awaccepts[N] = 1'b0;
			end

            // if (sha256_stall_trigger_wire)
            //     slave_awaccepts[N] = 1'b0;
		end
		// }}}

		// slave_waccepts
		// {{{
		always @(*)
		begin
			slave_waccepts[N] = 1'b1;
			if (!mwgrant[N])
				slave_waccepts[N] = 1'b0;
			if (!wdata_expected[N] && (!OPT_AWW || !slave_awaccepts[N]))
				slave_waccepts[N] = 1'b0;
			if (!wgrant[N][NS])
			begin
				if (!slave_wready[mwindex[N]])
					slave_waccepts[N] = 1'b0;
			end else if (berr_valid[N] && !bskd_ready[N])
				slave_waccepts[N] = 1'b0;

            // if (sha256_stall_trigger_wire)
            //     slave_waccepts[N] = 1'b0;
		end
		// }}}

		reg	r_awvalid;

		always @(*)
		begin
			r_awvalid = dcd_awvalid[N] && !mwfull[N];
			wrequest[N]= 0;
			if (!mwfull[N])
				wrequest[N][NS:0] = wdecode;
		end

		assign	m_awvalid[N] = r_awvalid;

		// QOS handling via write_qos_lockout
		// {{{
		if (!OPT_QOS || NM == 1)
		begin : WRITE_NO_QOS

			// If we aren't using QOS, then never lock any packets
			// out from arbitration
			assign	write_qos_lockout[N] = 0;

		end else begin : WRITE_QOS

			// Lock out a master based upon a second master having
			// a higher QOS request level
			// {{{
			reg	r_write_qos_lockout;

			initial	r_write_qos_lockout = 0;
			always @(posedge S_AXI_ACLK)
			if (!S_AXI_ARESETN)
				r_write_qos_lockout <= 0;
			else begin
				r_write_qos_lockout <= 0;

				for(iN=0; iN<NM; iN=iN+1)
				if (iN != N)
				begin
					if (m_awvalid[N]
						&&(|(wrequest[iN][NS-1:0]
							& wdecode[NS-1:0]))
						&&(m_awqos[N] < m_awqos[iN]))
						r_write_qos_lockout <= 1;
				end
			end

			assign	write_qos_lockout[N] = r_write_qos_lockout;
			// }}}
		end
		// }}}

	end for (N=NM; N<NMFULL; N=N+1)
	begin : UNUSED_WSKID_BUFFERS
	// {{{
		// The following values are unused.  They need to be defined
		// so that our indexing scheme will work, but indexes should
		// never actually reference them
		assign	m_awid[N]    = 0;
		assign	m_awaddr[N]  = 0;
		assign	m_awlen[N]   = 0;
		assign	m_awsize[N]  = 0;
		assign	m_awburst[N] = 0;
		assign	m_awlock[N]  = 0;
		assign	m_awcache[N] = 0;
		assign	m_awprot[N]  = 0;
		assign	m_awqos[N]   = 0;

		assign	m_awvalid[N] = 0;

		assign	m_wvalid[N]  = 0;
		//
		assign	m_wdata[N] = 0;
		assign	m_wstrb[N] = 0;
		assign	m_wlast[N] = 0;

		assign	write_qos_lockout[N] = 0;
	// }}}
	// }}}
	end endgenerate

	// Read skid buffers and address decoding, slave_araccepts logic
	generate for(N=0; N<NM; N=N+1)
	begin : R1_DECODE_READ_REQUEST
	// {{{
		reg		r_arvalid;
		wire	[NS:0]	rdecode;

		// arskid
		// {{{
		skidbuffer #(
			// {{{
			.DW(IW+AW+8+3+2+1+4+3+4),
			.OPT_OUTREG(OPT_SKID_INPUT)
			// }}}
		) arskid(
			// {{{
			S_AXI_ACLK, !S_AXI_ARESETN,
			S_AXI_ARVALID[N], S_AXI_ARREADY[N],
			{ S_AXI_ARID[N*IW +: IW], S_AXI_ARADDR[N*AW +: AW],
			  S_AXI_ARLEN[N*8 +: 8], S_AXI_ARSIZE[N*3 +: 3],
			  S_AXI_ARBURST[N*2 +: 2], S_AXI_ARLOCK[N],
			  S_AXI_ARCACHE[N*4 +: 4], S_AXI_ARPROT[N*3 +: 3],
			  S_AXI_ARQOS[N*4 +: 4] },
			skd_arvalid[N], !skd_arstall[N],
			{ skd_arid[N], skd_araddr[N], skd_arlen[N],
			  skd_arsize[N], skd_arburst[N], skd_arlock[N],
			  skd_arcache[N], skd_arprot[N], skd_arqos[N] }
			// }}}
		);
		// }}}

		// Read address decoder
		// {{{
		addrdecode #(
			// {{{
			.AW(AW), .DW(IW+8+3+2+1+4+3+4), .NS(NS),
			.SLAVE_ADDR(SLAVE_ADDR),
			.SLAVE_MASK(SLAVE_MASK),
			.OPT_REGISTERED(OPT_BUFFER_DECODER)
			// }}}
		) rdaddr(
			// {{{
			.i_clk(S_AXI_ACLK), .i_reset(!S_AXI_ARESETN),
			.i_valid(skd_arvalid[N]), .o_stall(skd_arstall[N]),
				.i_addr(skd_araddr[N]), .i_data({ skd_arid[N],
				skd_arlen[N], skd_arsize[N], skd_arburst[N],
				skd_arlock[N], skd_arcache[N], skd_arprot[N],
				skd_arqos[N] }),
			.o_valid(dcd_arvalid[N]),
				.i_stall(!m_arvalid[N] || !slave_raccepts[N]),
				.o_decode(rdecode), .o_addr(m_araddr[N]),
				.o_data({ m_arid[N], m_arlen[N], m_arsize[N],
				  m_arburst[N], m_arlock[N], m_arcache[N],
				  m_arprot[N], m_arqos[N]})
			// }}}
		);
		// }}}

		always @(*)
		begin
			r_arvalid = dcd_arvalid[N] && !mrfull[N];
			rrequest[N] = 0;
			if (!mrfull[N])
				rrequest[N][NS:0] = rdecode;
		end

		assign	m_arvalid[N] = r_arvalid;

		// slave_raccepts decoding
		// {{{
		always @(*)
		begin
			slave_raccepts[N] = 1'b1;
			if (!mrgrant[N])
				slave_raccepts[N] = 1'b0;
			if (read_qos_lockout[N])
				slave_raccepts[N] = 1'b0;
			if (mrfull[N])
				slave_raccepts[N] = 1'b0;
			// If we aren't requesting access to the channel we've
			// been granted access to, then we can't accept this
			// verilator lint_off  WIDTH
			if (!rrequest[N][mrindex[N]])
				slave_raccepts[N] = 1'b0;
			// verilator lint_on  WIDTH
			if (!rgrant[N][NS])
			begin
				if (!slave_arready[mrindex[N]])
					slave_raccepts[N] = 1'b0;
			end else if (!mrempty[N] || !rerr_none[N] || rskd_valid[N])
				slave_raccepts[N] = 1'b0;
		end
		// }}}

		// Read QOS logic
		// {{{
		// read_qos_lockout will get set if a master with a higher
		// QOS number is requesting a given slave.  It will not
		// affect existing outstanding packets, but will be used to
		// prevent further packets from being sent to a given slave.
		if (!OPT_QOS || NM == 1)
		begin : READ_NO_QOS

			// If we aren't implementing QOS, then the lockout
			// signal is never set
			assign	read_qos_lockout[N] = 0;

		end else begin : READ_QOS
			// {{{
			// We set lockout if another master (with a higher
			// QOS) is requesting this slave *and* the slave
			// channel is currently stalled.
			reg	r_read_qos_lockout;

			initial	r_read_qos_lockout = 0;
			always @(posedge  S_AXI_ACLK)
			if (!S_AXI_ARESETN)
				r_read_qos_lockout <= 0;
			else begin
				r_read_qos_lockout <= 0;

				for(iN=0; iN<NM; iN=iN+1)
				if (iN != N)
				begin
					if (m_arvalid[iN]
						&& !slave_raccepts[N]
						&&(|(rrequest[iN][NS-1:0]
							& rdecode[NS-1:0]))
						&&(m_arqos[N] < m_arqos[iN]))
						r_read_qos_lockout <= 1;
				end
			end

			assign	read_qos_lockout[N] = 0;
			// }}}
		end
		// }}}

	end for (N=NM; N<NMFULL; N=N+1)
	begin : UNUSED_RSKID_BUFFERS
	// {{{
		assign	m_arvalid[N] = 0;
		assign	m_arid[N]    = 0;
		assign	m_araddr[N]  = 0;
		assign	m_arlen[N]   = 0;
		assign	m_arsize[N]  = 0;
		assign	m_arburst[N] = 0;
		assign	m_arlock[N]  = 0;
		assign	m_arcache[N] = 0;
		assign	m_arprot[N]  = 0;
		assign	m_arqos[N]   = 0;

		assign	read_qos_lockout[N] = 0;
	// }}}
	// }}}
	end endgenerate
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Channel arbitration
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//

	// wrequested
	// {{{
	always @(*)
	begin : W2_DECONFLICT_WRITE_REQUESTS

		for(iN=0; iN<=NM; iN=iN+1)
			wrequested[iN] = 0;

		// Vivado may complain about too many bits for wrequested.
		// This is (currrently) expected.  mwindex is used to index
		// into wrequested, and mwindex has LGNS bits, where LGNS
		// is $clog2(NS+1) rather than $clog2(NS).  The extra bits
		// are defined to be zeros, but the point is they are defined.
		// Therefore, no matter what mwindex is, it will always
		// reference something valid.
		wrequested[NM] = 0;

		for(iM=0; iM<NS; iM=iM+1)
		begin
			wrequested[0][iM] = 1'b0;
			for(iN=1; iN<NM ; iN=iN+1)
			begin
				// Continue to request any channel with
				// a grant and pending operations
				if (wrequest[iN-1][iM] && wgrant[iN-1][iM])
					wrequested[iN][iM] = 1;
				if (wrequest[iN-1][iM] && (!mwgrant[iN-1]||mwempty[iN-1]))
					wrequested[iN][iM] = 1;
				// Otherwise, if it's already claimed, then
				// it can't be claimed again
				if (wrequested[iN-1][iM])
					wrequested[iN][iM] = 1;
			end
			wrequested[NM][iM] = wrequest[NM-1][iM] || wrequested[NM-1][iM];
		end
	end
	// }}}

	// rrequested
	// {{{
	always @(*)
	begin : R2_DECONFLICT_READ_REQUESTS

		for(iN=0; iN<NM ; iN=iN+1)
			rrequested[iN] = 0;

		// See the note above for wrequested.  This applies to
		// rrequested as well.
		rrequested[NM] = 0;

		for(iM=0; iM<NS; iM=iM+1)
		begin
			rrequested[0][iM] = 0;
			for(iN=1; iN<NM ; iN=iN+1)
			begin
				// Continue to request any channel with
				// a grant and pending operations
				if (rrequest[iN-1][iM] && rgrant[iN-1][iM])
					rrequested[iN][iM] = 1;
				if (rrequest[iN-1][iM] && (!mrgrant[iN-1] || mrempty[iN-1]))
					rrequested[iN][iM] = 1;
				// Otherwise, if it's already claimed, then
				// it can't be claimed again
				if (rrequested[iN-1][iM])
					rrequested[iN][iM] = 1;
			end
			rrequested[NM][iM] = rrequest[NM-1][iM] || rrequested[NM-1][iM];
		end
	end
	// }}}


	generate for(N=0; N<NM; N=N+1)
	begin : W3_ARBITRATE_WRITE_REQUESTS
	// {{{
		reg			stay_on_channel;
		reg			requested_channel_is_available;
		reg			leave_channel;
		reg	[LGNS-1:0]	requested_index;
		wire			linger;
		reg	[LGNS-1:0]	r_mwindex;

		// The basic logic:
		// 1. If we must stay_on_channel, then nothing changes
		// 2. If the requested channel isn't available, then no grant
		//   is issued
		// 3. Otherwise, if we need to leave this channel--such as if
		//   another master is requesting it, then we lose our grant

		// stay_on_channel
		// {{{
		// We must stay on the channel if we aren't done working with it
		// i.e. more writes requested, more acknowledgments expected,
		// etc.
		always @(*)
		begin
			stay_on_channel = |(wrequest[N][NS:0] & wgrant[N]);
			if (write_qos_lockout[N])
				stay_on_channel = 0;

			// We must stay on this channel until we've received
			// our last acknowledgment signal.  Only then can we
			// switch grants
			if (mwgrant[N] && !mwempty[N])
				stay_on_channel = 1;

			// if berr_valid is true, we have a grant to the
			// internal slave-error channel.  While this grant
			// exists, we cannot issue any others.
			if (berr_valid[N])
				stay_on_channel = 1;
		end
		// }}}

		// requested_channel_is_available
		// {{{
		always @(*)
		begin
			// The channel is available to us if 1) we want it,
			// 2) no one else is using it, and 3) no one earlier
			// has requested it
			requested_channel_is_available =
				|(wrequest[N][NS-1:0] & ~swgrant
						& ~wrequested[N][NS-1:0]);

			// Of course, the error pseudo-channel is *always*
			// available to us.
			if (wrequest[N][NS])
				requested_channel_is_available = 1;

			// Likewise, if we are the only master, then the
			// channel is always available on any request
			if (NM < 2)
				requested_channel_is_available = m_awvalid[N];
		end
		// }}}

		// Linger option, and setting the "linger" flag
		// {{{
		// If used, linger will hold on to a given channels grant
		// for some number of clock ticks after the channel has become
		// idle.  This will spare future requests from the same master
		// to the same slave from neding to go through the arbitration
		// clock cycle again--potentially saving a clock period.  If,
		// however, the master in question requests a different slave
		// or a different master requests this slave, then the linger
		// option is voided and the grant given up anyway.
		if (OPT_LINGER == 0)
		begin
			assign	linger = 0;
		end else begin : WRITE_LINGER

			reg [LGLINGER-1:0]	linger_counter;
			reg			r_linger;

			initial	r_linger = 0;
			initial	linger_counter = 0;
			always @(posedge S_AXI_ACLK)
			if (!S_AXI_ARESETN || wgrant[N][NS])
			begin
				r_linger <= 0;
				linger_counter <= 0;
			end else if (!mwempty[N] || bskd_valid[N])
			begin
				// While the channel is in use, we set the
				// linger counter
				linger_counter <= OPT_LINGER;
				r_linger <= 1;
			end else if (linger_counter > 0)
			begin
				// Otherwise, we decrement it until it reaches
				// zero
				r_linger <= (linger_counter > 1);
				linger_counter <= linger_counter - 1;
			end else
				r_linger <= 0;

			assign	linger = r_linger;
		end
		// }}}

		// leave_channel
		// {{{
		// True of another master is requesting access to this slave,
		// or if we are requesting access to another slave.  If QOS
		// lockout is enabled, then we also leave the channel if a
		// request with a higher QOS has arrived
		always @(*)
		begin
			leave_channel = 0;
			if (!m_awvalid[N]
				&& (!linger || wrequested[NM][mwindex[N]]))
				// Leave the channel after OPT_LINGER counts
				// of the channel being idle, or when someone
				// else asks for the channel
				leave_channel = 1;
			if (m_awvalid[N] && !wrequest[N][mwindex[N]])
				// Need to leave this channel to connect
				// to any other channel
				leave_channel = 1;
			if (write_qos_lockout[N])
				// Need to leave this channel for another higher
				// priority request
				leave_channel = 1;
		end
		// }}}

		// WRITE GRANT ALLOCATION
		// {{{
		// Now that we've done our homework, we can switch grants
		// if necessary
		initial	wgrant[N]  = 0;
		initial	mwgrant[N] = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			wgrant[N]  <= 0;
			mwgrant[N] <= 0;
		end else if (!stay_on_channel)
		begin
			if (requested_channel_is_available)
			begin
				// Switch to a new channel
				mwgrant[N] <= 1'b1;
				wgrant[N]  <= wrequest[N][NS:0];
			end else if (leave_channel)
			begin
				// Revoke the given grant
				mwgrant[N] <= 1'b0;
				wgrant[N]  <= 0;
			end
		end
		// }}}

		// mwindex (registered)
		// {{{
		always @(wrequest[N])
		begin
			requested_index = 0;
			for(iM=0; iM<=NS; iM=iM+1)
			if (wrequest[N][iM])
				requested_index= requested_index | iM[LGNS-1:0];
		end

		// Now for mwindex
		initial	r_mwindex = 0;
		always @(posedge S_AXI_ACLK)
		if (!stay_on_channel && requested_channel_is_available)
			r_mwindex <= requested_index;

		assign	mwindex[N] = r_mwindex;
		// }}}

	end for (N=NM; N<NMFULL; N=N+1)
	begin

		assign	mwindex[N] = 0;
	// }}}
	end endgenerate

	generate for(N=0; N<NM; N=N+1)
	begin : R3_ARBITRATE_READ_REQUESTS
	// {{{
		reg			stay_on_channel;
		reg			requested_channel_is_available;
		reg			leave_channel;
		reg	[LGNS-1:0]	requested_index;
		reg			linger;
		reg	[LGNS-1:0]	r_mrindex;


		// The basic logic:
		// 1. If we must stay_on_channel, then nothing changes
		// 2. If the requested channel isn't available, then no grant
		//   is issued
		// 3. Otherwise, if we need to leave this channel--such as if
		//   another master is requesting it, then we lose our grant

		// stay_on_channel
		// {{{
		// We must stay on the channel if we aren't done working with it
		// i.e. more reads requested, more acknowledgments expected,
		// etc.
		always @(*)
		begin
			stay_on_channel = |(rrequest[N][NS:0] & rgrant[N]);
			if (read_qos_lockout[N])
				stay_on_channel = 0;

			// We must stay on this channel until we've received
			// our last acknowledgment signal.  Only then can we
			// switch grants
			if (mrgrant[N] && !mrempty[N])
				stay_on_channel = 1;

			// if we have a grant to the internal slave-error
			// channel, then we cannot issue a grant to any other
			// while this grant is active
			if (rgrant[N][NS] && (!rerr_none[N] || rskd_valid[N]))
				stay_on_channel = 1;
		end
		// }}}

		// requested_channel_is_available
		// {{{
		always @(*)
		begin
			// The channel is available to us if 1) we want it,
			// 2) no one else is using it, and 3) no one earlier
			// has requested it
			requested_channel_is_available =
				|(rrequest[N][NS-1:0] & ~srgrant
						& ~rrequested[N][NS-1:0]);

			// Of course, the error pseudo-channel is *always*
			// available to us.
			if (rrequest[N][NS])
				requested_channel_is_available = 1;

			// Likewise, if we are the only master, then the
			// channel is always available on any request
			if (NM < 2)
				requested_channel_is_available = m_arvalid[N];
		end
		// }}}

		// Linger option, and setting the "linger" flag
		// {{{
		// If used, linger will hold on to a given channels grant
		// for some number of clock ticks after the channel has become
		// idle.  This will spare future requests from the same master
		// to the same slave from neding to go through the arbitration
		// clock cycle again--potentially saving a clock period.  If,
		// however, the master in question requests a different slave
		// or a different master requests this slave, then the linger
		// option is voided and the grant given up anyway.
		if (OPT_LINGER == 0)
		begin
			always @(*)
				linger = 0;
		end else begin : READ_LINGER

			reg [LGLINGER-1:0]	linger_counter;

			initial	linger = 0;
			initial	linger_counter = 0;
			always @(posedge S_AXI_ACLK)
			if (!S_AXI_ARESETN || rgrant[N][NS])
			begin
				linger <= 0;
				linger_counter <= 0;
			end else if (!mrempty[N] || rskd_valid[N])
			begin
				linger_counter <= OPT_LINGER;
				linger <= 1;
			end else if (linger_counter > 0)
			begin
				linger <= (linger_counter > 1);
				linger_counter <= linger_counter - 1;
			end else
				linger <= 0;

		end
		// }}}

		// leave_channel
		// {{{
		// True of another master is requesting access to this slave,
		// or if we are requesting access to another slave.  If QOS
		// lockout is enabled, then we also leave the channel if a
		// request with a higher QOS has arrived
		always @(*)
		begin
			leave_channel = 0;
			if (!m_arvalid[N]
				&& (!linger || rrequested[NM][mrindex[N]]))
				// Leave the channel after OPT_LINGER counts
				// of the channel being idle, or when someone
				// else asks for the channel
				leave_channel = 1;
			if (m_arvalid[N] && !rrequest[N][mrindex[N]])
				// Need to leave this channel to connect
				// to any other channel
				leave_channel = 1;
			if (read_qos_lockout[N])
				leave_channel = 1;
		end
		// }}}


		// READ GRANT ALLOCATION
		// {{{
		initial	rgrant[N]  = 0;
		initial	mrgrant[N] = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			rgrant[N]  <= 0;
			mrgrant[N] <= 0;
		end else if (!stay_on_channel)
		begin
			if (requested_channel_is_available)
			begin
				// Switching channels
				mrgrant[N] <= 1'b1;
				rgrant[N] <= rrequest[N][NS:0];
			end else if (leave_channel)
			begin
				mrgrant[N] <= 1'b0;
				rgrant[N]  <= 0;
			end
		end
		// }}}

		// mrindex (registered)
		// {{{
		always @(rrequest[N])
		begin
			requested_index = 0;
			for(iM=0; iM<=NS; iM=iM+1)
			if (rrequest[N][iM])
				requested_index = requested_index|iM[LGNS-1:0];
		end

		initial	r_mrindex = 0;
		always @(posedge S_AXI_ACLK)
		if (!stay_on_channel && requested_channel_is_available)
			r_mrindex <= requested_index;

		assign	mrindex[N] = r_mrindex;
		// }}}

	end for (N=NM; N<NMFULL; N=N+1)
	begin

		assign	mrindex[N] = 0;
	// }}}
	end endgenerate

	// Calculate swindex (registered)
	generate for (M=0; M<NS; M=M+1)
	begin : W4_SLAVE_WRITE_INDEX
	// {{{
		// swindex is a per slave index, containing the index of the
		// master that has currently won write arbitration and so
		// has permission to access this slave
		if (NM <= 1)
		begin

			// If there's only ever one master, that index is
			// always the index of the one master.
			assign	swindex[M] = 0;

		end else begin : MULTIPLE_MASTERS

			reg [LGNM-1:0]	reqwindex, r_swindex;

			// In the case of multiple masters, we follow the logic
			// of the arbiter to generate the appropriate index
			// here, and register it on the next clock cycle.  If
			// no slave has arbitration, the index will remain zero
			always @(*)
			begin
				reqwindex = 0;
			for(iN=0; iN<NM; iN=iN+1)
			if ((!mwgrant[iN] || mwempty[iN])
				&&(wrequest[iN][M] && !wrequested[iN][M]))
					reqwindex = reqwindex | iN[LGNM-1:0];
			end

			always @(posedge S_AXI_ACLK)
			if (!swgrant[M])
				r_swindex <= reqwindex;

			assign	swindex[M] = r_swindex;
		end

	end for (M=NS; M<NSFULL; M=M+1)
	begin

		assign	swindex[M] = 0;
	// }}}
	end endgenerate

	// Calculate srindex (registered)
	generate for (M=0; M<NS; M=M+1)
	begin : R4_SLAVE_READ_INDEX
	// {{{
		// srindex is an index to the master that has currently won
		// read arbitration to the given slave.

		if (NM <= 1)
		begin
			// If there's only one master, srindex can always
			// point to that master--no longic required
			assign	srindex[M] = 0;

		end else begin : MULTIPLE_MASTERS

			reg [LGNM-1:0]	reqrindex, r_srindex;

			// In the case of multiple masters, we'll follow the
			// read arbitration logic to generate the index--first
			// combinatorially, then we'll register it.
			always @(*)
			begin
				reqrindex = 0;
			for(iN=0; iN<NM; iN=iN+1)
			if ((!mrgrant[iN] || mrempty[iN])
				&&(rrequest[iN][M] && !rrequested[iN][M]))
					reqrindex = reqrindex | iN[LGNM-1:0];
			end

			always @(posedge S_AXI_ACLK)
			if (!srgrant[M])
				r_srindex <= reqrindex;

			assign	srindex[M] = r_srindex;
		end

	end for (M=NS; M<NSFULL; M=M+1)
	begin

		assign	srindex[M] = 0;
	// }}}
	end endgenerate

	// swgrant and srgrant (combinatorial)
	generate for(M=0; M<NS; M=M+1)
	begin : SGRANT
	// {{{

		// s?grant is a convenience to tell a slave that some master
		// has won arbitration and so has a grant to that slave.

		// swgrant: write arbitration
		initial	swgrant = 0;
		always @(*)
		begin
			swgrant[M] = 0;
			for(iN=0; iN<NM; iN=iN+1)
			if (wgrant[iN][M])
				swgrant[M] = 1;
		end

		initial	srgrant = 0;
		// srgrant: read arbitration
		always @(*)
		begin
			srgrant[M] = 0;
			for(iN=0; iN<NM; iN=iN+1)
			if (rgrant[iN][M])
				srgrant[M] = 1;
		end
	// }}}
	end endgenerate

	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Generate the signals for the various slaves--the forward channel
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// Assign outputs to the various slaves
	generate for(M=0; M<NS; M=M+1)
	begin : W5_WRITE_SLAVE_OUTPUTS
	// {{{
		reg			axi_awvalid;
		reg	[IW-1:0]	axi_awid;
		reg	[AW-1:0]	axi_awaddr;
		reg	[7:0]		axi_awlen;
		reg	[2:0]		axi_awsize;
		reg	[1:0]		axi_awburst;
		reg			axi_awlock;
		reg	[3:0]		axi_awcache;
		reg	[2:0]		axi_awprot;
		reg	[3:0]		axi_awqos;

		reg			axi_wvalid;
		reg	[DW-1:0]	axi_wdata;
		reg	[DW/8-1:0]	axi_wstrb;
		reg			axi_wlast;
		//
		reg			axi_bready;

		reg			sawstall, swstall;
		reg			awaccepts;

		// Control the slave's AW* channel
		// {{{

		// Personalize the slave_awaccepts signal
		always @(*)
			awaccepts = slave_awaccepts[swindex[M]];

		always @(*)
			sawstall= (M_AXI_AWVALID[M]&& !M_AXI_AWREADY[M]);

		initial	axi_awvalid = 0;
		always @(posedge  S_AXI_ACLK)
		if (!S_AXI_ARESETN || !swgrant[M])
			axi_awvalid <= 0;
		else if (!sawstall)
		begin
			axi_awvalid <= m_awvalid[swindex[M]] &&(awaccepts);
		end
        // else if (sawstall)
        //     axi_awvalid <= 0;

		initial	axi_awid    = 0;
		initial	axi_awaddr  = 0;
		initial	axi_awlen   = 0;
		initial	axi_awsize  = 0;
		initial	axi_awburst = 0;
		initial	axi_awlock  = 0;
		initial	axi_awcache = 0;
		initial	axi_awprot  = 0;
		initial	axi_awqos   = 0;
		always @(posedge  S_AXI_ACLK)
        if (OPT_LOWPOWER && (!S_AXI_ARESETN || !swgrant[M]))
        begin
            // Under the OPT_LOWPOWER option, we clear all signals
            // we aren't using
            axi_awid    <= 0;
            axi_awaddr  <= 0;
            axi_awlen   <= 0;
            axi_awsize  <= 0;
            axi_awburst <= 0;
            axi_awlock  <= 0;
            axi_awcache <= 0;
            axi_awprot  <= 0;
            axi_awqos   <= 0;
        end else if (!sawstall)
        begin

            if (!OPT_LOWPOWER||(m_awvalid[swindex[M]]&&awaccepts))
            begin
                // swindex[M] is defined as 0 above in the
                // case where NM <= 1
                axi_awid    <= m_awid[   swindex[M]];
                axi_awaddr  <= m_awaddr[ swindex[M]];
                axi_awlen   <= m_awlen[  swindex[M]];
                axi_awsize  <= m_awsize[ swindex[M]];
                axi_awburst <= m_awburst[swindex[M]];
                axi_awlock  <= m_awlock[ swindex[M]];
                axi_awcache <= m_awcache[swindex[M]];
                axi_awprot  <= m_awprot[ swindex[M]];
                axi_awqos   <= m_awqos[  swindex[M]];

            end else begin
                axi_awid    <= 0;
                axi_awaddr  <= 0;
                axi_awlen   <= 0;
                axi_awsize  <= 0;
                axi_awburst <= 0;
                axi_awlock  <= 0;
                axi_awcache <= 0;
                axi_awprot  <= 0;
                axi_awqos   <= 0;
            end
        end
		// }}}

        // Myles's reading on AW* channel
        always @(posedge S_AXI_ACLK)
        begin
            if (user_reset_signal)
            begin
                last_m_wr_addr_reg <= 0;
                current_writting_slice <= 0;
				slice_counter_for_switching_frame <= 0;

                outstanding_write_burst_transaction_counter_producer <= 0;
                for (i_for_outstanding_write_burst_transaction = 0; i_for_outstanding_write_burst_transaction < 16; i_for_outstanding_write_burst_transaction = i_for_outstanding_write_burst_transaction + 1)
                begin
                    outstanding_write_burst_transaction_valid[i_for_outstanding_write_burst_transaction] <= 0;
                    // outstanding_write_burst_transaction_len[i_for_outstanding_write_burst_transaction] <= 0;
                    // outstanding_write_burst_transaction_addr[i_for_outstanding_write_burst_transaction] <= 0;
                end
                is_too_many_outstanding_write_burst_transaction <= 0;

            end
            // else if (is_new_aw_transaction_ready && (M_AXI_AWADDR >= 32'h0D400000) && (M_AXI_AWADDR < 32'h0E2FFFFF) && (current_writting_slice <= turn_to_start_logging_sub))
            else if (is_new_aw_transaction_ready && (M_AXI_AWADDR >= 32'h0D400000) && (M_AXI_AWADDR < 32'h0E2FFFFF))
            begin
                
                if ((outstanding_write_burst_transaction_counter_producer + 1) == outstanding_write_burst_transaction_counter_consumer)
                begin
                    is_too_many_outstanding_write_burst_transaction <= 1;
                end
                // else
                // begin
                    outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_producer] <= 1;
                    // outstanding_write_burst_transaction_len[outstanding_write_burst_transaction_counter_producer] <= M_AXI_AWLEN;
                    // outstanding_write_burst_transaction_addr[outstanding_write_burst_transaction_counter_producer] <= M_AXI_AWADDR;
                    outstanding_write_burst_transaction_counter_producer <= outstanding_write_burst_transaction_counter_producer + 1;
                // end

                if ((M_AXI_AWADDR < last_m_wr_addr_reg) || ((last_m_wr_addr_reg + 32'h80) < M_AXI_AWADDR))
				begin
                    current_writting_slice <= current_writting_slice + 1;

					if (last_m_wr_addr_reg != 0)
						outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_producer] <= 2;

					// if ((slice_counter_for_switching_frame + 1) == NUM_OF_SLICES_PER_FRAME)
					// begin
					// 	outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_producer] <= 2;
					// 	slice_counter_for_switching_frame <= 0;
					// end
					// else
					// 	slice_counter_for_switching_frame <= slice_counter_for_switching_frame + 1;
				end

                last_m_wr_addr_reg <= M_AXI_AWADDR;
            end
            else if (is_new_aw_transaction_ready)
            begin

                if ((outstanding_write_burst_transaction_counter_producer + 1) == outstanding_write_burst_transaction_counter_consumer)
                begin
                        is_too_many_outstanding_write_burst_transaction <= 1;
                end
                // else
                // begin
                    outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_producer] <= 0;
                    // outstanding_write_burst_transaction_len[outstanding_write_burst_transaction_counter_producer] <= M_AXI_AWLEN;
                    // outstanding_write_burst_transaction_addr[outstanding_write_burst_transaction_counter_producer] <= M_AXI_AWADDR;
                    outstanding_write_burst_transaction_counter_producer <= outstanding_write_burst_transaction_counter_producer + 1;
                // end
            end
        end

		// Control the slave's W* channel
		// {{{
		always @(*)
			swstall = (M_AXI_WVALID[M] && !M_AXI_WREADY[M]);

		initial	axi_wvalid = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN || !swgrant[M])
			axi_wvalid <= 0;
		else if (!swstall)
		begin
			axi_wvalid <= (m_wvalid[swindex[M]])
					&&(slave_waccepts[swindex[M]]);
		end

		initial axi_wdata  = 0;
		initial axi_wstrb  = 0;
		initial axi_wlast  = 0;
		always @(posedge S_AXI_ACLK)
        begin
            if (OPT_LOWPOWER && !S_AXI_ARESETN)
            begin
                axi_wdata  <= 0;
                axi_wstrb  <= 0;
                axi_wlast  <= 0;
            end else if (OPT_LOWPOWER && !swgrant[M])
            begin
                axi_wdata  <= 0;
                axi_wstrb  <= 0;
                axi_wlast  <= 0;
            end else if (!swstall)
            begin
                if (!OPT_LOWPOWER || (m_wvalid[swindex[M]]&&slave_waccepts[swindex[M]]))
                begin
                    // If NM <= 1, swindex[M] is already defined
                    // to be zero above
                    axi_wdata  <= m_wdata[swindex[M]];
                    axi_wstrb  <= m_wstrb[swindex[M]];
                    axi_wlast  <= m_wlast[swindex[M]];

                end else begin
                    axi_wdata  <= 0;
                    axi_wstrb  <= 0;
                    axi_wlast  <= 0;
                end
            end
        end
		// }}}
	
		// rob e producer
		always @(posedge S_AXI_ACLK)
		begin
			if ((!S_AXI_ARESETN) || user_reset_signal)
			begin
				mem_e_r_data <= 0;
				current_writing_rob_e_addr <= 0;
				next_slice_rob_e_start_addr <= MEM_DDEPTH_4_E;
				current_reading_rob_e_addr_receipt <= MEM_DDEPTH_4_E;
				e_hasher_is_not_catching_up_counter <= 0;
				is_slice_switcher_just_marked <= 0;
				is_switching_to_next_slice <= 0;
				last_slice_switching_outstanding_burst_transaction_index_marker <= MAX_OUTSTANDING_WRITE_BURST_TRASACTIONS;
				is_mem_e_r_data_fresh <= 0;
				hasher_e_is_not_catching_up <= 0;
			end
			else if(mem_e_en_wire) 
			begin
				if(mem_e_wea_wire)
				begin
					// check if buffer is full
					if ((current_writing_rob_e_addr + 1) == current_reading_rob_e_addr)
						hasher_e_is_not_catching_up <= 1;

					// do write
					mem_e[current_writing_rob_e_addr] <= M_AXI_WDATA;

					// check if we are switching slice
					if ((!is_switching_to_next_slice) && (outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_consumer] - 1))
					begin
						if (!is_slice_switcher_just_marked)
						begin
							next_slice_rob_e_start_addr <= current_writing_rob_e_addr;
							is_slice_switcher_just_marked <= 1;
						end
					end
					else
						is_slice_switcher_just_marked <= 0;

					// do counter
					if ((current_writing_rob_e_addr + 1) == MEM_DDEPTH_4_E)
					begin
						current_writing_rob_e_addr <= 0;
					end
					else
						current_writing_rob_e_addr <= current_writing_rob_e_addr + 1;

					// check if e_hasher is catching up
					if ((current_writing_rob_e_addr + 1) == current_reading_rob_e_addr)
						e_hasher_is_not_catching_up_counter <= e_hasher_is_not_catching_up_counter + 1;
				end

				if (is_switching_to_next_slice_receipt)
					last_slice_switching_outstanding_burst_transaction_index_marker <= outstanding_write_burst_transaction_counter_consumer;
				else if (last_slice_switching_outstanding_burst_transaction_index_marker != outstanding_write_burst_transaction_counter_consumer)
					last_slice_switching_outstanding_burst_transaction_index_marker <= MAX_OUTSTANDING_WRITE_BURST_TRASACTIONS;
				
				// do read
				// first check if we are switching slice
				is_mem_e_r_data_fresh <= 0;
				if ((current_reading_rob_e_addr == next_slice_rob_e_start_addr) && (!is_switching_to_next_slice_receipt) && (last_slice_switching_outstanding_burst_transaction_index_marker != outstanding_write_burst_transaction_counter_consumer))
				begin
					is_switching_to_next_slice <= 1;
				end
				else if (current_writing_rob_e_addr != current_reading_rob_e_addr)
				begin
					mem_e_r_data <= mem_e[current_reading_rob_e_addr];
					current_reading_rob_e_addr_receipt <= current_reading_rob_e_addr;
					is_switching_to_next_slice <= 0;

					is_mem_e_r_data_fresh <= (current_reading_rob_e_addr_receipt != current_reading_rob_e_addr);
				end
			end
		end

		// rob e consumer
		// 1 + 1 latency
		// always @(posedge S_AXI_ACLK)
		// begin
		// 	if ((!S_AXI_ARESETN) || user_reset_signal)
		// 	begin
		// 		for (i_for_e_hasher_prepared_data = 0; i_for_e_hasher_prepared_data < E_HASHER_DATA_READER_DEPTH; i_for_e_hasher_prepared_data = i_for_e_hasher_prepared_data + 1)
		// 			e_hasher_prepared_data[i_for_e_hasher_prepared_data] <= 0;
		// 		current_preparing_e_frame_data_index <= 0;
		// 		current_reading_rob_e_addr <= 0;
		// 		e_hasher_data_producer <= 0;
		// 	end
		// 	else if ((e_hasher_data_producer == e_hasher_data_consumer) && (current_reading_rob_e_addr == current_reading_rob_e_addr_receipt))
		// 	begin
		// 		e_hasher_prepared_data[current_preparing_e_frame_data_index] <= mem_e_r_data;

		// 		// reading counter update
		// 		if ((current_reading_rob_e_addr + 1) == MEM_DDEPTH_4_E)
		// 		begin
		// 			current_reading_rob_e_addr <= 0;
		// 		end
		// 		else
		// 			current_reading_rob_e_addr <= current_reading_rob_e_addr + 1;

		// 		// check if is done
		// 		if ((current_preparing_e_frame_data_index + 1) == E_HASHER_DATA_READER_DEPTH)
		// 		begin
		// 			current_preparing_e_frame_data_index <= 0;
		// 			e_hasher_data_producer <= e_hasher_data_producer + 1;
		// 		end
		// 		else
		// 			current_preparing_e_frame_data_index <= current_preparing_e_frame_data_index + 1;
		// 	end
		// end

		// for resetting e_hasher
		always @(posedge S_AXI_ACLK)
		begin
			if ((!S_AXI_ARESETN) || user_reset_signal)
			begin
				sha256_e_rst_counter <= 0;
				sha256_digest_reg <= 256'h0;
			end
			else if (sha256_e_rst_signal)
			begin
				sha256_e_rst_counter <= sha256_e_rst_counter - 1;
			end
			else if (is_hashing_completed && (!sha256_stall_trigger_wire) && sha256_digest_valid_reg)
			begin
				sha256_e_rst_counter <= SHA256_RST_NUM_OF_CLOCKS;
				sha256_digest_reg <= sha256_core_digest;
			end
		end

		// e_hasher
		// rob e consumer
        always @(posedge S_AXI_ACLK)
        // always @(negedge S_AXI_ACLK)
        begin

            // For Myles's debugging
            if ((!S_AXI_ARESETN) || user_reset_signal)
            begin
                // Sha256 related
                for (i = 0 ; i < 16 ; i = i + 1)
                    sha256_block_reg[i] <= 32'h0;
                sha256_init_reg         <= 0;
                sha256_next_reg         <= 0;
                sha256_digest_valid_reg <= 0;
                sha256_init_next_just_set_reg <= 0;
                sha256_init_next_reg_reset_counter <= 0;
                sha256_hash_step_reg <= 0;
                is_hashing_completed <= 0;
                // sha256_ring_buffer_r_ptr <= 0;
                // sha256_final_size_to_hash_actual <= 0;
				is_switching_to_next_slice_receipt <= 0;
				slice_switching_delay_counter <= 0;
				current_preparing_e_frame_data_index <= 0;
				current_reading_rob_e_addr <= 0;
				sha256_final_size_to_hash_e <= 0;
            end
			// half reset
			else if (sha256_e_rst_signal)
			begin
                for (i = 0 ; i < 16 ; i = i + 1)
                    sha256_block_reg[i] <= 32'h0;
				sha256_block_reg[0] <= sha256_digest_reg[31:0];
				sha256_block_reg[1] <= sha256_digest_reg[63:32];
				sha256_block_reg[2] <= sha256_digest_reg[95:64];
				sha256_block_reg[3] <= sha256_digest_reg[127:96];
				sha256_block_reg[4] <= sha256_digest_reg[159:128];
				sha256_block_reg[5] <= sha256_digest_reg[191:160];
				sha256_block_reg[6] <= sha256_digest_reg[223:192];
				sha256_block_reg[7] <= sha256_digest_reg[255:224];
                sha256_init_reg         <= 0;
                sha256_next_reg         <= 0;
                sha256_digest_valid_reg <= 0;
                sha256_init_next_just_set_reg <= 0;
                sha256_init_next_reg_reset_counter <= 0;
                sha256_hash_step_reg <= 0;
                is_hashing_completed <= 0;
				is_switching_to_next_slice_receipt <= 0;
				slice_switching_delay_counter <= 0;
				current_preparing_e_frame_data_index <= 2;
				sha256_final_size_to_hash_e <= 256;
			end
            else
            begin
                sha256_digest_valid_reg <= sha256_core_digest_valid;

                // Myles: automatic init/next reset (to prevent recalculation)
                if (sha256_init_reg || sha256_next_reg)
                begin
                    if ((sha256_init_next_reg_reset_counter == 4) && (!sha256_init_next_just_set_reg))
                    begin
                        sha256_init_reg <= 0;
                        sha256_next_reg <= 0;
                    end
                    
                    if (sha256_init_next_just_set_reg)
                    begin
                        sha256_init_next_reg_reset_counter <= 0;
                        sha256_init_next_just_set_reg <= 0;
                    end
                    else
                        sha256_init_next_reg_reset_counter <= sha256_init_next_reg_reset_counter + 1;
                end

                // Read ring buffer
                if ((!is_hashing_completed) && (!sha256_stall_trigger_wire))
                begin
					if (current_reading_rob_e_addr == current_reading_rob_e_addr_receipt)
                    begin
						// clear it first
						if (current_preparing_e_frame_data_index == 0)
						begin
							for (i = 0 ; i < 16 ; i = i + 1)
                    			sha256_block_reg[i] <= 32'h0;
						end

						slice_switching_delay_counter <= 0;

						sha256_block_reg[current_preparing_e_frame_data_index*4] <= mem_e_r_data[31:0];
                        sha256_block_reg[current_preparing_e_frame_data_index*4 + 1] <= mem_e_r_data[63:32];
                        sha256_block_reg[current_preparing_e_frame_data_index*4 + 2] <= mem_e_r_data[95:64];
                        sha256_block_reg[current_preparing_e_frame_data_index*4 + 3] <= mem_e_r_data[127:96];

						// update hashed size
						sha256_final_size_to_hash_e <= sha256_final_size_to_hash_e + MEM_DWIDTH;

						// reading counter update
						if ((current_reading_rob_e_addr + 1) == MEM_DDEPTH_4_E)
						begin
							current_reading_rob_e_addr <= 0;
						end
						else
							current_reading_rob_e_addr <= current_reading_rob_e_addr + 1;

						// check if we can perform a round of hashing
						if ((current_preparing_e_frame_data_index + 1) == E_HASHER_DATA_READER_DEPTH)
						begin
							current_preparing_e_frame_data_index <= 0;
							case (sha256_hash_step_reg)
								0: sha256_init_reg <= 1;
								default: sha256_next_reg <= 1;
							endcase
							sha256_init_next_just_set_reg <= 1;

							sha256_hash_step_reg <= 1;
						end
						else
							current_preparing_e_frame_data_index <= current_preparing_e_frame_data_index + 1;
                    end
					if (is_switching_to_next_slice && (!is_switching_to_next_slice_receipt))
                    begin
						if (slice_switching_delay_counter == SLICE_SWITCHING_DELAY)
						begin
							is_switching_to_next_slice_receipt <= 1;
							slice_switching_delay_counter <= 0;
						end
						else
							slice_switching_delay_counter <= slice_switching_delay_counter + 1;
					end
					else if (is_switching_to_next_slice_receipt)
					begin
						is_switching_to_next_slice_receipt <= 0;

						// clear it first
						if (current_preparing_e_frame_data_index == 0)
						begin
							for (i = 0 ; i < 16 ; i = i + 1)
                    			sha256_block_reg[i] <= 32'h0;
						end

						sha256_block_reg[current_preparing_e_frame_data_index*4] <= 32'h80000000;
                        sha256_block_reg[14] <= sha256_final_size_to_hash_e[0:31];
                        sha256_block_reg[15] <= sha256_final_size_to_hash_e[32:63];

                        sha256_next_reg <= 1;
                        sha256_init_next_just_set_reg <= 1;
                        is_hashing_completed <= 1;
                    end
                end
            end
        end

		// For e_hasher to switch to next burst write transaction
		always @(posedge S_AXI_ACLK)
		begin
			if ((!S_AXI_ARESETN) || user_reset_signal)
			begin
				outstanding_write_burst_transaction_counter_consumer <= 0;
				outstanding_write_burst_transaction_current_counter <= 0;
			end
			else if (is_new_w_transaction_ready)
			begin
				if (M_AXI_WLAST)
				begin
					outstanding_write_burst_transaction_counter_consumer <= outstanding_write_burst_transaction_counter_consumer + 1;
					outstanding_write_burst_transaction_current_counter <= 0;
				end
				else
					outstanding_write_burst_transaction_current_counter <= outstanding_write_burst_transaction_current_counter + 1;
			end
		end

        // always @(posedge S_AXI_ACLK)
        // // always @(negedge S_AXI_ACLK)
        // // always @(user_reset_signal or is_new_w_transaction_ready)
        // begin
        //     if (user_reset_signal)
        //     begin
        //         sha256_ring_buffer_w_ptr <= 0;
        //         // sha256_final_size_to_hash <= 0;
        //         // burst_transaction_write_counter <= 1;
        //         for (i_for_fvs = 0; i_for_fvs < MAXSTOREDFIRSTVALUE; i_for_fvs = i_for_fvs + 1)
        //         begin
        //             // first_value_addr_storage[i_for_fvs] <= 0;
        //             first_value_storage[i_for_fvs] <= 0;
        //         end
        //         // outstanding_write_burst_transaction_counter_consumer <= 0;
        //         // current_burst_transaction_remaining_write_counter <= 0;

        //         // for (i_for_fvs_sub = 0; i_for_fvs_sub < 32; i_for_fvs_sub = i_for_fvs_sub + 1)
        //         //     sha256_debug_info[i_for_fvs_sub] <= 0;
        //         // sha256_debug_counter <= 0;
        //         // sha256_debug_counter_sub <= 0;

        //         // is_too_many_outstanding_write_buffer <= 0;
        //     end
        //     else if (is_new_w_transaction_ready && (current_writting_slice <= turn_to_start_logging_sub) && (current_writting_slice >= turn_to_start_logging))
        //     begin
        //         // if (!current_burst_transaction_remaining_write_counter)
        //         // begin
        //         //     current_burst_transaction_remaining_write_counter <= outstanding_write_burst_transaction_len[outstanding_write_burst_transaction_counter_consumer];
        //         // end
        //         // else
        //         // begin
        //         //     // burst_transaction_write_counter <= burst_transaction_write_counter + 1;
        //         //     current_burst_transaction_remaining_write_counter <= current_burst_transaction_remaining_write_counter - 1;
        //         // end

        //         if (outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_consumer] && M_AXI_WDATA && (sha256_ring_buffer_w_ptr < MAXSTOREDFIRSTVALUE4PTR))
        //         begin
        //             // // first_value_addr_storage[sha256_ring_buffer_w_ptr] <= outstanding_write_burst_transaction_addr[outstanding_write_burst_transaction_counter_consumer];
        //             first_value_storage[sha256_ring_buffer_w_ptr] <= M_AXI_WDATA;

		// 			sha256_ring_buffer_w_ptr <= sha256_ring_buffer_w_ptr + 8'd1;

        //             // if (sha256_ring_buffer_w_ptr == MAXSTOREDFIRSTVALUE4PTR)
        //             //     sha256_ring_buffer_w_ptr <= 0;
        //             // else
        //             //     sha256_ring_buffer_w_ptr <= sha256_ring_buffer_w_ptr + 8'd1;

        //             // if ((sha256_ring_buffer_w_ptr + 1) == sha256_ring_buffer_r_ptr || ((sha256_ring_buffer_w_ptr == MAXSTOREDFIRSTVALUE4PTR) && (sha256_ring_buffer_r_ptr == 0)))
        //             //     is_too_many_outstanding_write_buffer <= is_too_many_outstanding_write_buffer + 1;
                    
        //             // sha256_final_size_to_hash <= sha256_final_size_to_hash + C_AXI_DATA_WIDTH;
        //         end

        //         // if (M_AXI_WLAST)
        //         // begin
        //         //     // if (outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_consumer] && (outstanding_write_burst_transaction_len[outstanding_write_burst_transaction_counter_consumer] != burst_transaction_write_counter))
        //         //     // begin
        //         //     //     if (sha256_debug_counter_sub < 30)
        //         //     //     begin
        //         //     //         sha256_debug_info[sha256_debug_counter_sub] <= outstanding_write_burst_transaction_addr[outstanding_write_burst_transaction_counter_consumer];
        //         //     //         sha256_debug_info[sha256_debug_counter_sub+1] <= burst_transaction_write_counter;
        //         //     //         sha256_debug_info[sha256_debug_counter_sub+2] <= outstanding_write_burst_transaction_len[outstanding_write_burst_transaction_counter_consumer];
        //         //     //         sha256_debug_counter_sub <= sha256_debug_counter_sub + 3;
        //         //     //     end
        //         //     //     sha256_debug_counter <= sha256_debug_counter + 1;
        //         //     // end

        //         //     outstanding_write_burst_transaction_counter_consumer <= outstanding_write_burst_transaction_counter_consumer + 1;
        //         //     // burst_transaction_write_counter <= 1;
        //         // end
        //     end

        // end

		//
		always @(*)
		if (!swgrant[M])
			axi_bready = 1;
		else
			axi_bready = bskd_ready[swindex[M]];

        always @(DEBUG_START_TURN)
            turn_to_start_logging <= DEBUG_START_TURN;   // 0x4024_0000 0

        // always @(DEBUG_START_TURN_SUB)
        //     turn_to_start_logging_sub <= DEBUG_START_TURN_SUB;   // 0x4028_0000 1
        
        always @(DEBUG_INPUT_SIGNAL)
            user_reset_signal <= DEBUG_INPUT_SIGNAL;
    
        // assign GPIO_ADDR_OUT = sha256_ring_buffer_r_ptr;    // 0x4020_0000 0
        assign GPIO_ADDR_OUT = sha256_digest_reg[(7-turn_to_start_logging)*32 +: 32];    // 0x4020_0000 0
        // assign GPIO_ADDR_OUT = current_writting_slice;    // 0x4020_0000 0
        // assign GPIO_ADDR_OUT_1 = sha256_ring_buffer_w_ptr;  // 0x4020_0000 1
        // assign GPIO_ADDR_OUT_2 = first_value_addr_storage[turn_to_start_logging/4];   // 0x4021_0000 0
        // assign GPIO_ADDR_OUT_2 = e_hasher_is_not_catching_up_counter;   // 0x4021_0000 0
        // assign GPIO_ADDR_OUT_2 = outstanding_write_burst_transaction_valid[outstanding_write_burst_transaction_counter_consumer];   // 0x4021_0000 0
        // assign GPIO_ADDR_OUT_3 = first_value_storage[turn_to_start_logging/4][turn_to_start_logging*32 +: 32];   // 0x4021_0000 1
		// assign GPIO_ADDR_OUT_3 = mem_e_r_data;
        // assign GPIO_ADDR_OUT_4 = e_hasher_is_not_catching_up_counter;   // 0x4022_0000 0
        // assign GPIO_ADDR_OUT_4 = sha256_block_reg[0];   // 0x4022_0000 0
        // assign GPIO_ADDR_OUT_5 = sha256_digest_reg[(7-turn_to_start_logging)*32 +: 32];   // 0x4022_0000 1
        // assign GPIO_ADDR_OUT_6 = current_writting_slice;  // 0x4023_0000 0
        // assign GPIO_ADDR_OUT_7 = sha256_final_size_to_hash_e;  // 0x4023_0000 1
        // assign GPIO_ADDR_OUT_8 = sha256_final_size_to_hash_actual; // 0x4028_0000 0
        // assign DEBUG_MEM_R_DATA = raw_write_first_data[DEBUG_MEM_R_ADDR];
        // assign DEBUG_MEM_R_DATA = verification_error_reg;
        // assign DEBUG_MEM_R_DATA = mem_e_r_data[31:0];
        // assign DEBUG_MEM_R_DATA_1 = mem_e_r_data[63:32];
        // assign DEBUG_MEM_R_DATA_2 = mem_e_r_data[95:64];
        // assign DEBUG_MEM_R_DATA_3 = mem_e_r_data[127:96];
		// assign DEBUG_MEM_R_TOTAL = is_too_many_outstanding_raw_write_burst_transaction;
		// assign DEBUG_MEM_R_TOTAL = total_num_of_r_frames_read;
		// assign DEBUG_MEM_R_TOTAL = total_num_of_r_frames_hashed;
		// assign DEBUG_MEM_R_TOTAL = is_mem_e_r_data_fresh;
        // assign DEBUG_MEM_R_WARN = is_too_many_outstanding_raw_write_burst_transaction;
        // assign DEBUG_MEM_R_WARN = verification_error_reg;
        // assign DEBUG_MEM_R_ERR = is_too_many_outstanding_raw_write_burst_transaction + is_too_many_outstanding_write_burst_transaction + hashers_are_not_catching_up_counter + hasher_e_is_not_catching_up + sha256_error_reg_y + sha256_error_reg_uv + fatal_verification_error_reg;
        assign DEBUG_MEM_R_ERR = {26'b0, sha256_error_reg_y, sha256_error_reg_uv, hasher_e_is_not_catching_up, is_too_many_outstanding_write_burst_transaction, is_too_many_outstanding_raw_write_burst_transaction, hashers_are_not_catching_up_counter};
        assign SKIP_FRAME_INDICATOR = skip_frame_indicator_reg;
		// assign DEBUG_MEM_H_Y = generated_y_hash[DEBUG_MEM_R_ADDR];
		// assign DEBUG_MEM_H_UV = generated_uv_hash[DEBUG_MEM_R_ADDR];
		assign VERIFICATION_RESULT = verification_result_reg;

		// Combinatorial assigns
		// {{{
		assign	M_AXI_AWVALID[M]          = axi_awvalid;
		assign	M_AXI_AWID[   M*IW +: IW] = axi_awid;
		assign	M_AXI_AWADDR[ M*AW +: AW] = axi_awaddr;
		assign	M_AXI_AWLEN[  M* 8 +:  8] = axi_awlen;
		assign	M_AXI_AWSIZE[ M* 3 +:  3] = axi_awsize;
		assign	M_AXI_AWBURST[M* 2 +:  2] = axi_awburst;
		assign	M_AXI_AWLOCK[ M]          = axi_awlock;
		assign	M_AXI_AWCACHE[M* 4 +:  4] = axi_awcache;
		assign	M_AXI_AWPROT[ M* 3 +:  3] = axi_awprot;
		assign	M_AXI_AWQOS[  M* 4 +:  4] = axi_awqos;
		//
		//
		assign	M_AXI_WVALID[M]             = axi_wvalid;
		assign	M_AXI_WDATA[M*DW +: DW]     = axi_wdata;
		assign	M_AXI_WSTRB[M*DW/8 +: DW/8] = axi_wstrb;
		assign	M_AXI_WLAST[M]              = axi_wlast;
		//
		//
		assign	M_AXI_BREADY[M]             = axi_bready;
		// }}}
		//
	// }}}
	end endgenerate


	generate for(M=0; M<NS; M=M+1)
	begin : R5_READ_SLAVE_OUTPUTS
	// {{{
		reg				axi_arvalid;
		reg	[IW-1:0]		axi_arid;
		reg	[AW-1:0]		axi_araddr;
		reg	[7:0]			axi_arlen;
		reg	[2:0]			axi_arsize;
		reg	[1:0]			axi_arburst;
		reg				axi_arlock;
		reg	[3:0]			axi_arcache;
		reg	[2:0]			axi_arprot;
		reg	[3:0]			axi_arqos;
		//
		reg				axi_rready;
		reg				arstall;

		always @(*)
			arstall= axi_arvalid && !M_AXI_ARREADY[M];

		initial	axi_arvalid = 0;
		always @(posedge  S_AXI_ACLK)
		if (!S_AXI_ARESETN || !srgrant[M])
			axi_arvalid <= 0;
		else if (!arstall)
			axi_arvalid <= m_arvalid[srindex[M]] && slave_raccepts[srindex[M]];
		else if (M_AXI_ARREADY[M])
			axi_arvalid <= 0;

		initial axi_arid    = 0;
		initial axi_araddr  = 0;
		initial axi_arlen   = 0;
		initial axi_arsize  = 0;
		initial axi_arburst = 0;
		initial axi_arlock  = 0;
		initial axi_arcache = 0;
		initial axi_arprot  = 0;
		initial axi_arqos   = 0;
		always @(posedge  S_AXI_ACLK)
		if (OPT_LOWPOWER && (!S_AXI_ARESETN || !srgrant[M]))
		begin
			axi_arid    <= 0;
			axi_araddr  <= 0;
			axi_arlen   <= 0;
			axi_arsize  <= 0;
			axi_arburst <= 0;
			axi_arlock  <= 0;
			axi_arcache <= 0;
			axi_arprot  <= 0;
			axi_arqos   <= 0;
		end else if (!arstall)
		begin
			if (!OPT_LOWPOWER || (m_arvalid[srindex[M]] && slave_raccepts[srindex[M]]))
			begin
				// If NM <=1, srindex[M] is defined to be zero
				axi_arid    <= m_arid[   srindex[M]];
				axi_araddr  <= m_araddr[ srindex[M]];
				axi_arlen   <= m_arlen[  srindex[M]];
				axi_arsize  <= m_arsize[ srindex[M]];
				axi_arburst <= m_arburst[srindex[M]];
				axi_arlock  <= m_arlock[ srindex[M]];
				axi_arcache <= m_arcache[srindex[M]];
				axi_arprot  <= m_arprot[ srindex[M]];
				axi_arqos   <= m_arqos[  srindex[M]];
			end else begin
				axi_arid    <= 0;
				axi_araddr  <= 0;
				axi_arlen   <= 0;
				axi_arsize  <= 0;
				axi_arburst <= 0;
				axi_arlock  <= 0;
				axi_arcache <= 0;
				axi_arprot  <= 0;
				axi_arqos   <= 0;
			end
		end

		always @(*)
		if (!srgrant[M])
			axi_rready = 1;
		else
			axi_rready = rskd_ready[srindex[M]];

		//
		assign	M_AXI_ARVALID[M]          = axi_arvalid;
		assign	M_AXI_ARID[   M*IW +: IW] = axi_arid;
		assign	M_AXI_ARADDR[ M*AW +: AW] = axi_araddr;
		assign	M_AXI_ARLEN[  M* 8 +:  8] = axi_arlen;
		assign	M_AXI_ARSIZE[ M* 3 +:  3] = axi_arsize;
		assign	M_AXI_ARBURST[M* 2 +:  2] = axi_arburst;
		assign	M_AXI_ARLOCK[ M]          = axi_arlock;
		assign	M_AXI_ARCACHE[M* 4 +:  4] = axi_arcache;
		assign	M_AXI_ARPROT[ M* 3 +:  3] = axi_arprot;
		assign	M_AXI_ARQOS[  M* 4 +:  4] = axi_arqos;
		//
		assign	M_AXI_RREADY[M]          = axi_rready;
		//
	// }}}
	end endgenerate
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Generate the signals for the various masters--the return channel
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// Return values
	generate for (N=0; N<NM; N=N+1)
	begin : W6_WRITE_RETURN_CHANNEL
	// {{{
		reg	[1:0]	i_axi_bresp;
		reg	[IW-1:0] i_axi_bid;

		// Write error (no slave selected) state machine
		// {{{
		initial	berr_valid[N] = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
			berr_valid[N] <= 0;
		else if (wgrant[N][NS] && m_wvalid[N] && m_wlast[N]
				&& slave_waccepts[N])
			berr_valid[N] <= 1;
		else if (bskd_ready[N])
			berr_valid[N] <= 0;

		always @(*)
		if (berr_valid[N])
			bskd_valid[N] = 1;
		else
			bskd_valid[N] = mwgrant[N]&&m_axi_bvalid[mwindex[N]];

		always @(posedge S_AXI_ACLK)
		if (m_awvalid[N] && slave_awaccepts[N])
			berr_id[N] <= m_awid[N];

		always @(*)
		if (wgrant[N][NS])
		begin
			i_axi_bid   = berr_id[N];
			i_axi_bresp = INTERCONNECT_ERROR;
		end else begin
			i_axi_bid   = m_axi_bid[mwindex[N]];
			i_axi_bresp = m_axi_bresp[mwindex[N]];
		end
		// }}}

		// bskid, the B* channel skidbuffer
		// {{{
		skidbuffer #(
			// {{{
			.DW(IW+2),
			.OPT_LOWPOWER(OPT_LOWPOWER),
			.OPT_OUTREG(1)
			// }}}
		) bskid(
			// {{{
			S_AXI_ACLK, !S_AXI_ARESETN,
			bskd_valid[N], bskd_ready[N],
			{ i_axi_bid, i_axi_bresp },
			S_AXI_BVALID[N], S_AXI_BREADY[N],
			{ S_AXI_BID[N*IW +: IW], S_AXI_BRESP[N*2 +: 2] }
			// }}}
		);
		// }}}
	// }}}
	end endgenerate

	// Return values
	generate for (N=0; N<NM; N=N+1)
	begin : R6_READ_RETURN_CHANNEL
	// {{{

		reg	[DW-1:0]	i_axi_rdata;
		reg	[IW-1:0]	i_axi_rid;
		reg	[2-1:0]		i_axi_rresp;

		// generate the read response
		// {{{
		// Here we have two choices.  We can either generate our
		// response from the slave itself, or from our internally
		// generated (no-slave exists) FSM.
		always @(*)
		if (rgrant[N][NS])
			rskd_valid[N] = !rerr_none[N];
		else
			rskd_valid[N] = mrgrant[N] && m_axi_rvalid[mrindex[N]];

		always @(*)
		if (rgrant[N][NS])
		begin
			i_axi_rid   = rerr_id[N];
			i_axi_rdata = 0;
			rskd_rlast[N] = rerr_last[N];
			i_axi_rresp = INTERCONNECT_ERROR;
		end else begin
			i_axi_rid   = m_axi_rid[mrindex[N]];
			i_axi_rdata = m_axi_rdata[mrindex[N]];
			rskd_rlast[N]= m_axi_rlast[mrindex[N]];
			i_axi_rresp = m_axi_rresp[mrindex[N]];
		end
		// }}}

		// rskid, the outgoing read skidbuffer
		// {{{
		// Since our various read signals are all combinatorially
		// determined, we'll throw them into an outgoing skid buffer
		// to register them (per spec) and to make it easier to meet
		// timing.
		skidbuffer #(
			// {{{
			.DW(IW+DW+1+2),
			.OPT_LOWPOWER(OPT_LOWPOWER),
			.OPT_OUTREG(1)
			// }}}
		) rskid(
			// {{{
			S_AXI_ACLK, !S_AXI_ARESETN,
			rskd_valid[N], rskd_ready[N],
			{ i_axi_rid, i_axi_rdata, rskd_rlast[N], i_axi_rresp },
			S_AXI_RVALID[N], S_AXI_RREADY[N],
			{ S_AXI_RID[N*IW +: IW], S_AXI_RDATA[N*DW +: DW],
			  S_AXI_RLAST[N], S_AXI_RRESP[N*2 +: 2] }
			// }}}
		);
		// }}}
	// }}}
	end endgenerate
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Count pending transactions
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	generate for (N=0; N<NM; N=N+1)
	begin : W7_COUNT_PENDING_WRITES
	// {{{

		reg	[LGMAXBURST-1:0]	awpending, wpending;
		reg				r_wdata_expected;

		// awpending, and the associated flags mwempty and mwfull
		// {{{
		// awpending is a count of all of the AW* packets that have
		// been forwarded to the slave, but for which the slave has
		// yet to return a B* response.  This number can be as large
		// as (1<<LGMAXBURST)-1.  The two associated flags, mwempty
		// and mwfull, are there to keep us from checking awempty==0
		// and &awempty respectively.
		initial	awpending    = 0;
		initial	mwempty[N]   = 1;
		initial	mwfull[N]    = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			awpending     <= 0;
			mwempty[N]    <= 1;
			mwfull[N]     <= 0;
		end else case ({(m_awvalid[N] && slave_awaccepts[N]),
				(bskd_valid[N] && bskd_ready[N])})
		2'b01: begin
			awpending     <= awpending - 1;
			mwempty[N]    <= (awpending <= 1);
			mwfull[N]     <= 0;
			end
		2'b10: begin
			awpending <= awpending + 1;
			mwempty[N] <= 0;
			mwfull[N]     <= &awpending[LGMAXBURST-1:1];
			end
		default: begin end
		endcase

		// Just so we can access this counter elsewhere, let's make
		// it available outside of this generate block.  (The formal
		// section uses this.)
		assign	w_mawpending[N] = awpending;
		// }}}

		// r_wdata_expected and wdata_expected
		// {{{
		// This section keeps track of whether or not we are expecting
		// more W* data from the given burst.  It's designed to keep us
		// from accepting new W* information before the AW* portion
		// has been routed to the new slave.
		//
		// Addition: wpending.  wpending counts the number of write
		// bursts that are pending, based upon the write channel.
		// Bursts are counted from AWVALID & AWREADY, and decremented
		// once we see the WVALID && WREADY signal.  Packets should
		// not be accepted without a prior (or concurrent)
		// AWVALID && AWREADY.
		initial	r_wdata_expected = 0;
		initial	wpending = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			r_wdata_expected <= 0;
			wpending <= 0;
		end else case ({(m_awvalid[N] && slave_awaccepts[N]),
				(m_wvalid[N]&&slave_waccepts[N] && m_wlast[N])})
		2'b01: begin
			r_wdata_expected <= (wpending > 1);
			wpending <= wpending - 1;
			end
		2'b10: begin
			wpending <= wpending + 1;
			r_wdata_expected <= 1;
			end
		default: begin end
		endcase

		assign	wdata_expected[N] = r_wdata_expected;

		assign wlasts_pending[N] = wpending;
		// }}}
	// }}}
	end endgenerate

	generate for (N=0; N<NM; N=N+1)
	begin : R7_COUNT_PENDING_READS
	// {{{

		reg	[LGMAXBURST-1:0]	rpending;

		// rpending, and its associated mrempty and mrfull
		// {{{
		// rpending counts the number of read transactions that have
		// been accepted, but for which rlast has yet to be returned.
		// This specifically counts grants to valid slaves.  The error
		// slave is excluded from this count.  mrempty and mrfull have
		// analogous definitions to mwempty and mwfull, being equal to
		// rpending == 0 and (&rpending) respectfully.
		initial	rpending     = 0;
		initial	mrempty[N]   = 1;
		initial	mrfull[N]    = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			rpending  <= 0;
			mrempty[N]<= 1;
			mrfull[N] <= 0;
		end else case ({(m_arvalid[N] && slave_raccepts[N] && !rgrant[N][NS]),
				(rskd_valid[N] && rskd_ready[N]
					&& rskd_rlast[N] && !rgrant[N][NS])})
		2'b01: begin
			rpending      <= rpending - 1;
			mrempty[N]    <= (rpending == 1);
			mrfull[N]     <= 0;
			end
		2'b10: begin
			rpending      <= rpending + 1;
			mrfull[N]     <= &rpending[LGMAXBURST-1:1];
			mrempty[N]    <= 0;
			end
		default: begin end
		endcase

		assign	w_mrpending[N]  = rpending;
		// }}}

		// Read error state machine, rerr_outstanding and rerr_id
		// {{{
		// rerr_outstanding is the count of read *beats* that remain
		// to be returned to a master from a non-existent slave.
		// rerr_last is true on the last of these read beats,
		// equivalent to rerr_outstanding == 1, and rerr_none is true
		// when the error state machine is idle
		initial	rerr_outstanding[N] = 0;
		initial	rerr_last[N] = 0;
		initial	rerr_none[N] = 1;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN)
		begin
			rerr_outstanding[N] <= 0;
			rerr_last[N] <= 0;
			rerr_none[N] <= 1;
		end else if (!rerr_none[N])
		begin
			if (!rskd_valid[N] || rskd_ready[N])
			begin
				rerr_none[N] <= (rerr_outstanding[N] == 1);
				rerr_last[N] <= (rerr_outstanding[N] == 2);
				rerr_outstanding[N] <= rerr_outstanding[N] - 1;
			end
		end else if (m_arvalid[N] && rrequest[N][NS]
						&& slave_raccepts[N])
		begin
			rerr_none[N] <= 0;
			rerr_last[N] <= (m_arlen[N] == 0);
			rerr_outstanding[N] <= m_arlen[N] + 1;
		end

		// rerr_id is the ARID field of the currently outstanding
		// error.  It's used when generating a read response to a
		// non-existent slave.
		initial	rerr_id[N] = 0;
		always @(posedge S_AXI_ACLK)
		if (!S_AXI_ARESETN && OPT_LOWPOWER)
			rerr_id[N] <= 0;
		else if (m_arvalid[N] && slave_raccepts[N])
		begin
			if (rrequest[N][NS] || !OPT_LOWPOWER)
				// A low-logic definition
				rerr_id[N] <= m_arid[N];
			else
				rerr_id[N] <= 0;
		end else if (OPT_LOWPOWER && rerr_last[N]
				&& (!rskd_valid[N] || rskd_ready[N]))
			rerr_id[N] <= 0;
		// }}}

`ifdef	FORMAL
		always @(*)
			assert(rerr_none[N] ==  (rerr_outstanding[N] == 0));
		always @(*)
			assert(rerr_last[N] ==  (rerr_outstanding[N] == 1));
		always @(*)
		if (OPT_LOWPOWER && rerr_none[N])
			assert(rerr_id[N] ==  0);
`endif
	// }}}
	end endgenerate
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// (Partial) Parameter validation
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	initial begin
		if (NM == 0) begin
                        $display("At least one master must be defined");
                        $stop;
                end

		if (NS == 0) begin
                        $display("At least one slave must be defined");
                        $stop;
                end
        end
	// }}}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal property verification section
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	localparam	F_LGDEPTH = LGMAXBURST+9;

	////////////////////////////////////////////////////////////////////////
	//
	// Declare signals used for formal checking
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	//
	// ...
	//
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Initial/reset value checking
	// {{{
	initial	assert(NS >= 1);
	initial	assert(NM >= 1);
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Check the arbiter signals for consistency
	// {{{
	generate for(N=0; N<NM; N=N+1)
	begin : F1_CHECK_MASTER_GRANTS
	// {{{
		// Write grants
		always @(*)
		for(iM=0; iM<=NS; iM=iM+1)
		begin
			if (wgrant[N][iM])
			begin
				assert((wgrant[N] ^ (1<<iM))==0);
				assert(mwgrant[N]);
				assert(mwindex[N] == iM);
				if (iM < NS)
				begin
					assert(swgrant[iM]);
					assert(swindex[iM] == N);
				end
			end
		end

		always @(*)
		if (mwgrant[N])
			assert(wgrant[N] != 0);

		always @(*)
		if (wrequest[N][NS])
			assert(wrequest[N][NS-1:0] == 0);


		always @(posedge S_AXI_ACLK)
		if (S_AXI_ARESETN && f_past_valid && bskd_valid[N])
		begin
			assert($stable(wgrant[N]));
			assert($stable(mwindex[N]));
		end

		////////////////////////////////////////////////////////////////
		//
		// Read grant checking
		//
		always @(*)
		for(iM=0; iM<=NS; iM=iM+1)
		begin
			if (rgrant[N][iM])
			begin
				assert((rgrant[N] ^ (1<<iM))==0);
				assert(mrgrant[N]);
				assert(mrindex[N] == iM);
				if (iM < NS)
				begin
					assert(srgrant[iM]);
					assert(srindex[iM] == N);
				end
			end
		end

		always @(*)
		if (mrgrant[N])
			assert(rgrant[N] != 0);

		always @(posedge S_AXI_ACLK)
		if (S_AXI_ARESETN && f_past_valid && S_AXI_RVALID[N])
		begin
			assert($stable(rgrant[N]));
			assert($stable(mrindex[N]));
			if (!rgrant[N][NS])
				assert(!mrempty[N]);
		end
	// }}}
	end endgenerate
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI signaling check, (incoming) master side
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	generate for(N=0; N<NM; N=N+1)
	begin : F2_CHECK_MASTERS
	// {{{
		faxi_slave #(
			.C_AXI_ID_WIDTH(IW),
			.C_AXI_DATA_WIDTH(DW),
			.C_AXI_ADDR_WIDTH(AW),
			.F_OPT_ASSUME_RESET(1'b1),
			.F_AXI_MAXSTALL(0),
			.F_AXI_MAXRSTALL(2),
			.F_AXI_MAXDELAY(0),
			.F_OPT_READCHECK(0),
			.F_OPT_NO_RESET(1),
			.F_LGDEPTH(F_LGDEPTH))
		  mstri(.i_clk(S_AXI_ACLK),
			.i_axi_reset_n(S_AXI_ARESETN),
			//
			.i_axi_awid(   S_AXI_AWID[   N*IW +:IW]),
			.i_axi_awaddr( S_AXI_AWADDR[ N*AW +:AW]),
			.i_axi_awlen(  S_AXI_AWLEN[  N* 8 +: 8]),
			.i_axi_awsize( S_AXI_AWSIZE[ N* 3 +: 3]),
			.i_axi_awburst(S_AXI_AWBURST[N* 2 +: 2]),
			.i_axi_awlock( S_AXI_AWLOCK[ N]),
			.i_axi_awcache(S_AXI_AWCACHE[N* 4 +: 4]),
			.i_axi_awprot( S_AXI_AWPROT[ N* 3 +: 3]),
			.i_axi_awqos(  S_AXI_AWQOS[  N* 4 +: 4]),
			.i_axi_awvalid(S_AXI_AWVALID[N]),
			.i_axi_awready(S_AXI_AWREADY[N]),
			//
			.i_axi_wdata( S_AXI_WDATA[ N*DW   +: DW]),
			.i_axi_wstrb( S_AXI_WSTRB[ N*DW/8 +: DW/8]),
			.i_axi_wlast( S_AXI_WLAST[ N]),
			.i_axi_wvalid(S_AXI_WVALID[N]),
			.i_axi_wready(S_AXI_WREADY[N]),
			//
			.i_axi_bid(   S_AXI_BID[   N*IW +:IW]),
			.i_axi_bresp( S_AXI_BRESP[ N*2 +: 2]),
			.i_axi_bvalid(S_AXI_BVALID[N]),
			.i_axi_bready(S_AXI_BREADY[N]),
			//
			.i_axi_arid(   S_AXI_ARID[   N*IW +:IW]),
			.i_axi_arready(S_AXI_ARREADY[N]),
			.i_axi_araddr( S_AXI_ARADDR[ N*AW +:AW]),
			.i_axi_arlen(  S_AXI_ARLEN[  N* 8 +: 8]),
			.i_axi_arsize( S_AXI_ARSIZE[ N* 3 +: 3]),
			.i_axi_arburst(S_AXI_ARBURST[N* 2 +: 2]),
			.i_axi_arlock( S_AXI_ARLOCK[ N]),
			.i_axi_arcache(S_AXI_ARCACHE[N* 4 +: 4]),
			.i_axi_arprot( S_AXI_ARPROT[ N* 3 +: 3]),
			.i_axi_arqos(  S_AXI_ARQOS[  N* 4 +: 4]),
			.i_axi_arvalid(S_AXI_ARVALID[N]),
			//
			//
			.i_axi_rid(   S_AXI_RID[   N*IW +: IW]),
			.i_axi_rdata( S_AXI_RDATA[ N*DW +: DW]),
			.i_axi_rresp( S_AXI_RRESP[ N* 2 +: 2]),
			.i_axi_rlast( S_AXI_RLAST[ N]),
			.i_axi_rvalid(S_AXI_RVALID[N]),
			.i_axi_rready(S_AXI_RREADY[N]),
			//
			// ...
			//
			);

		//
		// ...
		//

		//
		// Check full/empty flags
		//

		always @(*)
		begin
			assert(mwfull[N] == &w_mawpending[N]);
			assert(mwempty[N] == (w_mawpending[N] == 0));
		end

		always @(*)
		begin
			assert(mrfull[N] == &w_mrpending[N]);
			assert(mrempty[N] == (w_mrpending[N] == 0));
		end
	// }}}
	end endgenerate
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// AXI signaling check, (outgoing) slave side
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	generate for(M=0; M<NS; M=M+1)
	begin : F3_CHECK_SLAVES
	// {{{
		faxi_master #(
			.C_AXI_ID_WIDTH(IW),
			.C_AXI_DATA_WIDTH(DW),
			.C_AXI_ADDR_WIDTH(AW),
			.F_OPT_ASSUME_RESET(1'b1),
			.F_AXI_MAXSTALL(2),
			.F_AXI_MAXRSTALL(0),
			.F_AXI_MAXDELAY(2),
			.F_OPT_READCHECK(0),
			.F_OPT_NO_RESET(1),
			.F_LGDEPTH(F_LGDEPTH))
		  slvi(.i_clk(S_AXI_ACLK),
			.i_axi_reset_n(S_AXI_ARESETN),
			//
			.i_axi_awid(   M_AXI_AWID[   M*IW+:IW]),
			.i_axi_awaddr( M_AXI_AWADDR[ M*AW +: AW]),
			.i_axi_awlen(  M_AXI_AWLEN[  M*8 +: 8]),
			.i_axi_awsize( M_AXI_AWSIZE[ M*3 +: 3]),
			.i_axi_awburst(M_AXI_AWBURST[M*2 +: 2]),
			.i_axi_awlock( M_AXI_AWLOCK[ M]),
			.i_axi_awcache(M_AXI_AWCACHE[M*4 +: 4]),
			.i_axi_awprot( M_AXI_AWPROT[ M*3 +: 3]),
			.i_axi_awqos(  M_AXI_AWQOS[  M*4 +: 4]),
			.i_axi_awvalid(M_AXI_AWVALID[M]),
			.i_axi_awready(M_AXI_AWREADY[M]),
			//
			.i_axi_wready(M_AXI_WREADY[M]),
			.i_axi_wdata( M_AXI_WDATA[ M*DW   +: DW]),
			.i_axi_wstrb( M_AXI_WSTRB[ M*DW/8 +: DW/8]),
			.i_axi_wlast( M_AXI_WLAST[ M]),
			.i_axi_wvalid(M_AXI_WVALID[M]),
			//
			.i_axi_bid(   M_AXI_BID[   M*IW +: IW]),
			.i_axi_bresp( M_AXI_BRESP[ M*2 +: 2]),
			.i_axi_bvalid(M_AXI_BVALID[M]),
			.i_axi_bready(M_AXI_BREADY[M]),
			//
			.i_axi_arid(   M_AXI_ARID[   M*IW +:IW]),
			.i_axi_araddr( M_AXI_ARADDR[ M*AW +:AW]),
			.i_axi_arlen(  M_AXI_ARLEN[  M*8  +: 8]),
			.i_axi_arsize( M_AXI_ARSIZE[ M*3  +: 3]),
			.i_axi_arburst(M_AXI_ARBURST[M*2  +: 2]),
			.i_axi_arlock( M_AXI_ARLOCK[ M]),
			.i_axi_arcache(M_AXI_ARCACHE[M* 4 +: 4]),
			.i_axi_arprot( M_AXI_ARPROT[ M* 3 +: 3]),
			.i_axi_arqos(  M_AXI_ARQOS[  M* 4 +: 4]),
			.i_axi_arvalid(M_AXI_ARVALID[M]),
			.i_axi_arready(M_AXI_ARREADY[M]),
			//
			//
			.i_axi_rresp( M_AXI_RRESP[ M*2 +: 2]),
			.i_axi_rvalid(M_AXI_RVALID[M]),
			.i_axi_rdata( M_AXI_RDATA[ M*DW +: DW]),
			.i_axi_rready(M_AXI_RREADY[M]),
			.i_axi_rlast( M_AXI_RLAST[ M]),
			.i_axi_rid(   M_AXI_RID[   M*IW +: IW]),
			//
			// ...
			//
			);

			//
			// ...
			//

		always @(*)
		if (M_AXI_AWVALID[M])
			assert(((M_AXI_AWADDR[M*AW +:AW]^SLAVE_ADDR[M*AW +:AW])
				& SLAVE_MASK[M*AW +: AW]) == 0);

		always @(*)
		if (M_AXI_ARVALID[M])
			assert(((M_AXI_ARADDR[M*AW +:AW]^SLAVE_ADDR[M*AW +:AW])
				& SLAVE_MASK[M*AW +: AW]) == 0);
	// }}}
	end endgenerate
	// }}}

	// m_axi_* convenience signals
	// {{{
	// ...
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// ...
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	generate for(N=0; N<NM; N=N+1)
	begin : // ...
	// {{{
	// }}}
	end endgenerate
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Double buffer checks
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	generate for(N=0; N<NM; N=N+1)
	begin : F4_DOUBLE_BUFFER_CHECKS
	// {{{
	// ...
	// }}}
	end endgenerate
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Cover properties
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	// Can every master reach every slave?
	// Can things transition without dropping the request line(s)?
	generate for(N=0; N<NM; N=N+1)
	begin : F5_COVER_CONNECTIVITY_FROM_MASTER
	// {{{
	// ...
	// }}}
	end endgenerate

	////////////////////////////////////////////////////////////////////////
	//
	// Focused check: How fast can one master talk to each of the slaves?
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	// ...
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Focused check: How fast can one master talk to a particular slave?
	// We'll pick master 1 and slave 1.
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
	// ...
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Poor man's cover check
	// {{{
	// ...
	// }}}
	// }}}
	////////////////////////////////////////////////////////////////////////
	//
	// Negation check
	// {{{
	// Pick a particular value.  Assume the value doesn't show up on the
	// input.  Prove it doesn't show up on the output.  This will check for
	// ...
	// 1. Stuck bits on the output channel
	// 2. Cross-talk between channels
	//
	////////////////////////////////////////////////////////////////////////
	//
	//
	// ...
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Artificially constraining assumptions
	// {{{
	// Ideally, this section should be empty--there should be no
	// assumptions here.  The existence of these assumptions should
	// give you an idea of where I'm at with this project.
	//
	////////////////////////////////////////////////////////////////////////
	//
	//
	generate for(N=0; N<NM; N=N+1)
	begin : F6_LIMITING_ASSUMPTIONS

		if (!OPT_WRITES)
		begin
			always @(*)
				assume(S_AXI_AWVALID[N] == 0);
			always @(*)
				assert(wgrant[N] == 0);
			always @(*)
				assert(mwgrant[N] == 0);
			always @(*)
				assert(S_AXI_BVALID[N]== 0);
		end

		if (!OPT_READS)
		begin
			always @(*)
				assume(S_AXI_ARVALID [N]== 0);
			always @(*)
				assert(rgrant[N] == 0);
			always @(*)
				assert(S_AXI_RVALID[N] == 0);
		end

	end endgenerate

	always@(*)
		assert(OPT_READS | OPT_WRITES);
	// }}}
`endif
// }}}
endmodule
