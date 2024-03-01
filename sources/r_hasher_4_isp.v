////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	r_hasher_4_isp.v
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
module	r_hasher_4_isp #(
		// {{{
		parameter integer C_AXI_DATA_WIDTH = 128,
		parameter integer C_AXI_ADDR_WIDTH = 32,
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
		parameter [0:0]	OPT_LOWPOWER = 0,
		// }}}
		//
		// OPT_LINGER: Set this to the number of clocks an idle
		// {{{
		// channel shall be left open before being closed.  Once
		// closed, it will take a minimum of two clocks before the
		// channel can be opened and data transmitted through it again.
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
		parameter	LGMAXBURST = 16,
		// }}}
		// }}}

        // frame parameters
		parameter [11:0] PIXEL_Y_SIZE_IN_BITS = 8,
		parameter [11:0] PIXEL_UV_SIZE_IN_BITS = 4,
		parameter [11:0] FRAME_WIDTH = 1280,
		parameter [11:0] FRAME_HEIGHT = 720,
		parameter [11:0] ENCODER_BLOCK_HEIGHT = 16,
        parameter [11:0] NUM_OF_FRAMES_TO_SKIP = 2, // for skipping the first N frames
        parameter [11:0] NUM_OF_FRAMES_TO_REPEAT = 1, // for using the first frame's hashes extra N times

        // uram parameters
        parameter MEM_AWIDTH = 12,  // Address Width
        parameter MEM_DWIDTH = 128,  // Data Width
        parameter MEM_DDEPTH_4_Y = 1024,  // Data Depth for RB of raw Y
        parameter MEM_DDEPTH_4_UV = 512,  // Data Depth for RB of raw UV (typically should be half of MEM_DDEPTH_4_Y)
		// parameter MEM_DDEPTH_4_H = 120,	// data Depth for hashes
		parameter MEM_DDEPTH_4_H = 240,	// data Depth for hashes

		// sha256
		parameter SHA256_RST_NUM_OF_CLOCKS = 10,
		parameter    [6:0]    SHA256_BLOCK_SIZE_IN_BYTES = 64,
		parameter	[8:0]    SHA256_HASH_SIZE_IN_BITS = 256,

		// r_hasher
		parameter [31:0] R_FRAME_Y_START_ADDR = 32'hc400000
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

        input   wire     [31:0]              DEBUG_INPUT_SIGNAL,    // for reset
        input   wire     [31:0]              DEBUG_MEM_R_ADDR,
        output  wire     [31:0]              DEBUG_MEM_R_DATA_Y,
        output  wire     [31:0]              DEBUG_MEM_R_DATA_UV,
        // output  wire     [31:0]              DEBUG_OUTPUT_EXTRA_0,
        // output  wire     [31:0]              DEBUG_OUTPUT_EXTRA_1,
        output  wire     [31:0]              DEBUG_OUTPUT_EXTRA_2,
        output  wire     [255:0]             Y_HASH_OUT,
        output  wire     [255:0]             UV_HASH_OUT,
        output  wire     [0:0]               IS_HASH_READY,
        input   wire     [0:0]               VERIFICATION_RESULT,
        // input   wire     [31:0]              ERROR_INDICATOR,
        input   wire     [0:0]               SKIP_FRAME_INDICATOR 

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

    // SHA256 localparams
    localparam MODE_SHA_256   = 1'h1;
	localparam	[5:0]    SHA256_HASH_SIZE_IN_BYTES = SHA256_HASH_SIZE_IN_BITS / 8;
	localparam  [1:0]	 SHA256_NUM_OF_CYCLES_NEEDED_4_URAM_W = SHA256_HASH_SIZE_IN_BITS / MEM_DWIDTH;

	// frame localparams
	localparam PIXEL_SIZE_IN_BITS = PIXEL_Y_SIZE_IN_BITS + PIXEL_UV_SIZE_IN_BITS;
	localparam [31:0] FRAME_NUM_OF_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
	localparam [64:0] R_FRAME_Y_SIZE_IN_BITS = FRAME_NUM_OF_PIXELS * PIXEL_Y_SIZE_IN_BITS;
	localparam [31:0] R_FRAME_Y_SIZE_IN_BYTES = R_FRAME_Y_SIZE_IN_BITS / 8;
	localparam [64:0] R_FRAME_UV_SIZE_IN_BITS = FRAME_NUM_OF_PIXELS * PIXEL_UV_SIZE_IN_BITS;
	localparam [31:0] R_FRAME_UV_SIZE_IN_BYTES = R_FRAME_UV_SIZE_IN_BITS / 8;
	localparam R_FRAME_SIZE_IN_BITS = FRAME_NUM_OF_PIXELS * PIXEL_SIZE_IN_BITS;
	localparam R_FRAME_SIZE_IN_BYTES = R_FRAME_SIZE_IN_BITS / 8;
	localparam R_FRAME_UV_START_ADDR = R_FRAME_Y_START_ADDR + FRAME_NUM_OF_PIXELS;	// absolute addr
	localparam R_FRAME_END_ADDR = R_FRAME_Y_START_ADDR + R_FRAME_SIZE_IN_BYTES;
	localparam [31:0] R_FRAME_BLOCK_OFFSET = FRAME_WIDTH * ENCODER_BLOCK_HEIGHT * PIXEL_SIZE_IN_BITS / 8;	// size of each block in r_frame (in bytes)
	localparam NUM_OF_READ_EACH_BLOCK = R_FRAME_BLOCK_OFFSET * 8 / MEM_DWIDTH;
	localparam NUM_OF_BLOCKS_EACH_FRAME = FRAME_HEIGHT / ENCODER_BLOCK_HEIGHT;

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

    // uram declaration
    (* ram_style = "ultra" *)
    (* cascade_height = 16 *)
    reg [MEM_DWIDTH-1:0] rb_y[MEM_DDEPTH_4_Y-1:0];
	(* ram_style = "ultra" *)
    (* cascade_height = 16 *)
    reg [MEM_DWIDTH-1:0] rb_uv[MEM_DDEPTH_4_UV-1:0];
	(* ram_style = "ultra" *)
    (* cascade_height = 16 *)
    reg [MEM_DWIDTH-1:0] rb_h_4_y[MEM_DDEPTH_4_H-1:0];
	(* ram_style = "ultra" *)
    (* cascade_height = 16 *)
    reg [MEM_DWIDTH-1:0] rb_h_4_uv[MEM_DDEPTH_4_H-1:0];
	wire rb_y_wea_wire;
	wire rb_uv_wea_wire;
	wire rb_h_4_y_wea_wire;
	wire rb_h_4_uv_wea_wire;
	wire rb_y_en_wire;
	wire rb_uv_en_wire;
	wire rb_h_4_y_en_wire;
	wire rb_h_4_uv_en_wire;
    reg [MEM_AWIDTH-1:0] rb_y_addr_producer;
    reg [MEM_AWIDTH-1:0] rb_uv_addr_producer;
    reg [MEM_AWIDTH-1:0] rb_h_4_y_addr_producer;
    reg [MEM_AWIDTH-1:0] rb_h_4_uv_addr_producer;
    reg [MEM_AWIDTH-1:0] rb_y_addr_consumer;
    reg [MEM_AWIDTH-1:0] rb_y_addr_consumer_receipt;
    reg [MEM_AWIDTH-1:0] rb_uv_addr_consumer;
    reg [MEM_AWIDTH-1:0] rb_uv_addr_consumer_receipt;
    reg [MEM_AWIDTH-1:0] rb_h_4_addr_consumer;
    reg [MEM_AWIDTH-1:0] rb_h_4_addr_consumer_receipt_y;
    reg [MEM_AWIDTH-1:0] rb_h_4_addr_consumer_receipt_uv;
    reg [MEM_DWIDTH-1:0] rb_y_r_data;
    reg [MEM_DWIDTH-1:0] rb_uv_r_data;
    reg [MEM_DWIDTH-1:0] rb_h_4_y_r_data;
    reg [MEM_DWIDTH-1:0] rb_h_4_uv_r_data;
	reg [2:0] remaining_num_of_writes_for_hash_y;	// as the hash is larger than width of uram, we need more than one cycle to write it
	reg [2:0] remaining_num_of_writes_for_hash_uv;	// as the hash is larger than width of uram, we need more than one cycle to write it
    integer is_rb_y_full;   // debug
    integer is_rb_uv_full;  // debug
    integer is_rb_h_4_y_full;  // debug
    integer is_rb_h_4_uv_full;  // debug

	// frame and hashing tracking
    // reg [31:0] total_num_of_r_frames_write;

	// finished hashes tracking
	reg [MEM_AWIDTH-1:0] hashes_counter_producer;	// should be in sync with rb_y_addr_consumer and rb_uv_addr_consumer
	reg [MEM_AWIDTH-1:0] hashes_counter_consumer;

    // general purpose declaration
    reg user_reset_signal;
    wire user_reset_wire;
    wire is_new_aw_ready;
    wire is_new_w_ready;

    // for tracking outstanding write transactions
    reg [3:0] outstanding_raw_write_burst_transaction_counter_producer;
    reg [3:0] outstanding_raw_write_burst_transaction_counter_consumer;
	reg [3:0] counter_4_skipping_frames;	// need to skip the first N frames in order to match
	reg [7:0] outstanding_raw_write_burst_transaction_current_counter;  // debug
    reg [1:0] outstanding_raw_write_burst_transaction_valid [15:0]; // 0 invalid; 1 Y; 2 UV; 3 undefined?
    reg [7:0] outstanding_raw_write_burst_transaction_len [15:0];   // debug
    reg [C_AXI_ADDR_WIDTH-1:0] outstanding_raw_write_burst_transaction_addr [15:0];
    reg [4:0] i_for_outstanding_raw_write_burst_transaction;
    // reg [5:0] i_for_raw_write_first_data;   // debug
	// integer counter_for_raw_write_first_data;   // debug
    // reg [31:0] raw_write_first_data [31:0]; // debug
    integer is_too_many_outstanding_raw_write_burst_transaction;    // debug
	wire [1:0] current_writing_type;	// align with outstanding_raw_write_burst_transaction_valid

	// sha256 generic
	wire [0:63] sha256_final_size_4_y_be;
	wire [0:63] sha256_final_size_4_uv_be;
	wire sha256_rst_signal;	// for resetting sha256 cores between each frame
	reg [5:0] sha256_rst_counter;

	// sha256 y
	reg [127:0] prepared_r_frame_y_data [3:0];
	reg [1:0] current_preparing_r_frame_y_data;
	reg prepared_r_frame_y_data_producer;
	reg prepared_r_frame_y_data_consumer;
	reg [31:0] current_hashing_r_frame_y_total_size_in_bytes;
	reg [31 : 0] sha256_block_reg_y [0 : 15];
    wire           sha256_core_ready_y;
    wire [255 : 0] sha256_core_digest_y;
    wire           sha256_core_digest_valid_y;
    reg            sha256_core_digest_valid_y_reg;
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
    // reg [31:0] debug_y_frame_hashes [31:0]; // debug
    // reg [5:0] i_for_debug_y_frame_hashes;   // debug
    // reg debug_y_frame_hashes_refresh_n;   // debug
    wire can_proceed_showing_new_hash;

	// sha256 uv
	reg [127:0] prepared_r_frame_uv_data [3:0];
	reg [1:0] current_preparing_r_frame_uv_data;
	reg prepared_r_frame_uv_data_producer;
	reg prepared_r_frame_uv_data_consumer;
	reg [31:0] current_hashing_r_frame_uv_total_size_in_bytes;
	reg [31 : 0] sha256_block_reg_uv [0 : 15];
    wire           sha256_core_ready_uv;
    wire [255 : 0] sha256_core_digest_uv;
    wire           sha256_core_digest_valid_uv;
    reg            sha256_core_digest_valid_uv_reg;
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

	// verification
	reg [255:0] sha256_digest_verification_reg_y;
	reg [255:0] sha256_digest_verification_reg_uv;
	reg [1:0] i_4_reading_verification_hash;
	reg counter_4_repeating_first_frame;
	reg init_indicator_4_verification;  // show that if hashes are ready

    // general purpose assignment
    assign user_reset_wire = !user_reset_signal;
    assign is_new_aw_ready = M_AXI_AWVALID && M_AXI_AWREADY;
    assign is_new_w_ready = M_AXI_WVALID && M_AXI_WREADY && M_AXI_WSTRB;
	assign current_writing_type = outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_consumer];
	assign sha256_rst_signal = (sha256_rst_counter > 0);
    // assign can_proceed_showing_new_hash = VERIFICATION_RESULT || ERROR_INDICATOR || SKIP_FRAME_INDICATOR;
    assign can_proceed_showing_new_hash = VERIFICATION_RESULT || SKIP_FRAME_INDICATOR;

    // raw ring buffer assignment
    assign rb_y_wea_wire = is_new_w_ready && (current_writing_type == 1);
    assign rb_uv_wea_wire = is_new_w_ready && (current_writing_type == 2);
	// assign rb_y_en_wire = rb_y_wea_wire || (prepared_r_frame_y_data_producer == prepared_r_frame_y_data_consumer) || total_num_of_r_frames_write;
	assign rb_y_en_wire = rb_y_wea_wire || (rb_y_addr_consumer_receipt != rb_y_addr_consumer);
    // assign rb_uv_en_wire = rb_uv_wea_wire || (prepared_r_frame_uv_data_producer == prepared_r_frame_uv_data_consumer) || total_num_of_r_frames_write;
    assign rb_uv_en_wire = rb_uv_wea_wire || (rb_uv_addr_consumer_receipt != rb_uv_addr_consumer);
   
	// hash ring buffer assignment
    assign rb_h_4_y_wea_wire = (remaining_num_of_writes_for_hash_y > 0);
	// assign rb_h_4_y_wea_wire = (remaining_num_of_writes_for_hash_y && (rb_h_4_y_addr_producer < MEM_DDEPTH_4_H));
	assign rb_h_4_uv_wea_wire = (remaining_num_of_writes_for_hash_uv > 0);
	// assign rb_h_4_uv_wea_wire = (remaining_num_of_writes_for_hash_uv && (rb_h_4_uv_addr_producer < MEM_DDEPTH_4_H));
    // assign rb_h_4_y_en_wire = rb_h_4_y_wea_wire || is_hash_ready_to_be_written_y || (i_4_reading_verification_hash < 2);
    assign rb_h_4_y_en_wire = rb_h_4_y_wea_wire || is_hash_ready_to_be_written_y || (i_4_reading_verification_hash < 2);
    // assign rb_h_4_uv_en_wire = rb_h_4_uv_wea_wire || is_hash_ready_to_be_written_uv || (i_4_reading_verification_hash < 2);
    assign rb_h_4_uv_en_wire = rb_h_4_uv_wea_wire || is_hash_ready_to_be_written_uv || (i_4_reading_verification_hash < 2);

    // I/O assignment
    // assign DEBUG_MEM_R_DATA_Y = rb_h_4_y_r_data;
    assign DEBUG_MEM_R_DATA_Y = sha256_digest_verification_reg_y;
    // assign DEBUG_MEM_R_DATA_UV = rb_h_4_uv_r_data;
    assign DEBUG_MEM_R_DATA_UV = sha256_digest_verification_reg_uv;
	// assign DEBUG_OUTPUT_EXTRA_0 = raw_write_first_data[DEBUG_MEM_R_ADDR];
	// assign DEBUG_OUTPUT_EXTRA_0 = debug_y_frame_hashes[DEBUG_MEM_R_ADDR];
    // assign DEBUG_OUTPUT_EXTRA_1 = total_num_of_r_frames_write;
    assign DEBUG_OUTPUT_EXTRA_2 = is_rb_y_full + is_rb_uv_full + is_rb_h_4_y_full + is_rb_h_4_uv_full + sha256_error_reg_y + sha256_error_reg_uv;	// debug: for displaying error (if any)
	assign Y_HASH_OUT = sha256_digest_verification_reg_y;
	// assign Y_HASH_OUT = rb_h_4_y_r_data;
	assign UV_HASH_OUT = sha256_digest_verification_reg_uv;
	// assign UV_HASH_OUT = rb_h_4_uv_r_data;

	// sha256 assignment
	assign sha256_final_size_4_y_be = {R_FRAME_Y_SIZE_IN_BITS[7:0], R_FRAME_Y_SIZE_IN_BITS[15:8], R_FRAME_Y_SIZE_IN_BITS[23:16], R_FRAME_Y_SIZE_IN_BITS[31:24], R_FRAME_Y_SIZE_IN_BITS[39:32], R_FRAME_Y_SIZE_IN_BITS[47:40], R_FRAME_Y_SIZE_IN_BITS[55:48], R_FRAME_Y_SIZE_IN_BITS[63:56]};
	assign sha256_final_size_4_uv_be = {R_FRAME_UV_SIZE_IN_BITS[7:0], R_FRAME_UV_SIZE_IN_BITS[15:8], R_FRAME_UV_SIZE_IN_BITS[23:16], R_FRAME_UV_SIZE_IN_BITS[31:24], R_FRAME_UV_SIZE_IN_BITS[39:32], R_FRAME_UV_SIZE_IN_BITS[47:40], R_FRAME_UV_SIZE_IN_BITS[55:48], R_FRAME_UV_SIZE_IN_BITS[63:56]};
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

    // output that shows if hashes are ready
    assign IS_HASH_READY = init_indicator_4_verification;

    // general purpose combinational logic
    always @(DEBUG_INPUT_SIGNAL)
            user_reset_signal <= DEBUG_INPUT_SIGNAL;

	// SHA256 core y
    sha256_core core_y(
                    .clk(S_AXI_ACLK),
                    .reset_n(user_reset_wire && (!sha256_rst_signal)),

                    .init(sha256_init_reg_y),
                    .next(sha256_next_reg_y),
                    .mode(MODE_SHA_256),

                    .block(sha256_core_block_y),

                    .ready(sha256_core_ready_y),

                    .digest(sha256_core_digest_y),
                    .digest_valid(sha256_core_digest_valid_y)
                   );

	// SHA256 core uv
    sha256_core core_uv(
                    .clk(S_AXI_ACLK),
                    .reset_n(user_reset_wire && (!sha256_rst_signal)),

                    .init(sha256_init_reg_uv),
                    .next(sha256_next_reg_uv),
                    .mode(MODE_SHA_256),

                    .block(sha256_core_block_uv),

                    .ready(sha256_core_ready_uv),

                    .digest(sha256_core_digest_uv),
                    .digest_valid(sha256_core_digest_valid_uv)
                   );

    // track outstanding write transactions
    always @(posedge S_AXI_ACLK)
    begin
        if ((!S_AXI_ARESETN) || user_reset_signal)
        begin
            outstanding_raw_write_burst_transaction_counter_producer <= 0;
			counter_4_skipping_frames <= 0;
            for (i_for_outstanding_raw_write_burst_transaction = 0; i_for_outstanding_raw_write_burst_transaction < 16; i_for_outstanding_raw_write_burst_transaction = i_for_outstanding_raw_write_burst_transaction + 1)
            begin
                outstanding_raw_write_burst_transaction_valid[i_for_outstanding_raw_write_burst_transaction] <= 0;
                outstanding_raw_write_burst_transaction_len[i_for_outstanding_raw_write_burst_transaction] <= 0;
                outstanding_raw_write_burst_transaction_addr[i_for_outstanding_raw_write_burst_transaction] <= 0;
            end
            is_too_many_outstanding_raw_write_burst_transaction <= 0;
        end
        else if (is_new_aw_ready)
        begin
            if ((outstanding_raw_write_burst_transaction_counter_producer + 1) == outstanding_raw_write_burst_transaction_counter_consumer)
            begin
                is_too_many_outstanding_raw_write_burst_transaction <= is_too_many_outstanding_raw_write_burst_transaction + 1;
            end
            else
            begin
                outstanding_raw_write_burst_transaction_counter_producer <= outstanding_raw_write_burst_transaction_counter_producer + 1;
                outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_producer] <= 0;

				if ((M_AXI_AWADDR >= R_FRAME_Y_START_ADDR) && (M_AXI_AWADDR < R_FRAME_UV_START_ADDR))
                    outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_producer] <= 1;
                else if ((M_AXI_AWADDR >= R_FRAME_UV_START_ADDR) && (M_AXI_AWADDR < R_FRAME_END_ADDR))
                    outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_producer] <= 2;
                
				// check if we still need to skip frames
				if (counter_4_skipping_frames < NUM_OF_FRAMES_TO_SKIP)
				begin
					outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_producer] <= 0;

					// mark as a frame if a certian address is reached
					if (M_AXI_AWADDR == R_FRAME_Y_START_ADDR)
						counter_4_skipping_frames <= counter_4_skipping_frames + 1;
				end
				else if (counter_4_skipping_frames == NUM_OF_FRAMES_TO_SKIP)
				begin
					if (M_AXI_AWADDR == R_FRAME_Y_START_ADDR)
						counter_4_skipping_frames <= counter_4_skipping_frames + 1;
					else
						outstanding_raw_write_burst_transaction_valid[outstanding_raw_write_burst_transaction_counter_producer] <= 0;
				end
				
				outstanding_raw_write_burst_transaction_len[outstanding_raw_write_burst_transaction_counter_producer] <= M_AXI_AWLEN;
                outstanding_raw_write_burst_transaction_addr[outstanding_raw_write_burst_transaction_counter_producer] <= M_AXI_AWADDR;
            end
        end
    end

	// for syncing outstanding_raw_write_burst_transaction_counter_consumer
	always @(posedge S_AXI_ACLK)
    begin
        if ((!S_AXI_ARESETN) || user_reset_signal)
        begin
            outstanding_raw_write_burst_transaction_counter_consumer <= 0;
			outstanding_raw_write_burst_transaction_current_counter <= 0;
        end
        else if (is_new_w_ready)
        begin
			if (M_AXI_WLAST)
			begin
            	outstanding_raw_write_burst_transaction_counter_consumer <= outstanding_raw_write_burst_transaction_counter_consumer + 1;
				outstanding_raw_write_burst_transaction_current_counter <= 0;
			end
			else
				outstanding_raw_write_burst_transaction_current_counter <= outstanding_raw_write_burst_transaction_current_counter + 1;
        end
    end

	// for syncing number of frames read
	// always @(posedge S_AXI_ACLK)
	// begin
	// 	if ((!S_AXI_ARESETN) || user_reset_signal)
	// 	begin
	// 		total_num_of_r_frames_write <= 0;

	// 		// Debug
	// 		// counter_for_raw_write_first_data <= 0;
	// 		// for (i_for_raw_write_first_data = 0; i_for_raw_write_first_data < 32; i_for_raw_write_first_data = i_for_raw_write_first_data + 1)
    //         // begin
    //         //     raw_write_first_data[i_for_raw_write_first_data] <= 0;
    //         // end
	// 	end
	// 	else if (is_new_w_ready && (outstanding_raw_write_burst_transaction_addr[outstanding_raw_write_burst_transaction_counter_consumer] == R_FRAME_Y_START_ADDR) && (!outstanding_raw_write_burst_transaction_current_counter))
	// 	begin
	// 		total_num_of_r_frames_write <= total_num_of_r_frames_write + 1;

	// 		// Debug
	// 		// if (counter_for_raw_write_first_data < 32)
	// 		// begin
	// 		// 	raw_write_first_data[counter_for_raw_write_first_data] <= M_AXI_WDATA;
	// 		// 	counter_for_raw_write_first_data <= counter_for_raw_write_first_data + 1;
	// 		// end
	// 	end
	// end

    // I/O Y ring buffer
    always @(posedge S_AXI_ACLK)
    begin
        if ((!S_AXI_ARESETN) || user_reset_signal)
        begin
            rb_y_addr_producer <= 0;
            is_rb_y_full <= 0;
            rb_y_r_data <= 0;
			rb_y_addr_consumer_receipt <= 1;
        end
        else if (rb_y_en_wire)
        begin
			// read
			if ((rb_y_addr_consumer != rb_y_addr_producer) && (rb_y_addr_consumer_receipt != rb_y_addr_consumer))
			begin
				rb_y_r_data <= rb_y[rb_y_addr_consumer];
				rb_y_addr_consumer_receipt <= rb_y_addr_consumer;
			end

			// write
            if (rb_y_wea_wire)
            begin
                if ((rb_y_addr_producer + 1) == rb_y_addr_consumer)
                begin
                    is_rb_y_full <= is_rb_y_full + 1;
                end
                else
                begin
                    rb_y[rb_y_addr_producer] <= M_AXI_WDATA;
                    rb_y_addr_producer <= rb_y_addr_producer + 1;

                    // clear it if max depth is reached
                    if ((rb_y_addr_producer + 1) == MEM_DDEPTH_4_Y)
                        rb_y_addr_producer <= 0;
                end

				// if read and write are at the same address, the new data will be read
				// if (rb_y_addr_consumer == rb_y_addr_producer)
				// 	rb_y_r_data <= M_AXI_WDATA;
            end
        end
    end

    // I/O UV ring buffer
    always @(posedge S_AXI_ACLK)
    begin
        if ((!S_AXI_ARESETN) || user_reset_signal)
        begin
            rb_uv_addr_producer <= 0;
            is_rb_uv_full <= 0;
            rb_uv_r_data <= 0;
			rb_uv_addr_consumer_receipt <= 1;
        end
        else if (rb_uv_en_wire)
        begin
			// read
			if ((rb_uv_addr_consumer != rb_uv_addr_producer) && (rb_uv_addr_consumer_receipt != rb_uv_addr_consumer))
			begin
				rb_uv_r_data <= rb_uv[rb_uv_addr_consumer];
				rb_uv_addr_consumer_receipt <= rb_uv_addr_consumer;
			end

			// write
            if (rb_uv_wea_wire)
            begin
                if ((rb_uv_addr_producer + 1) == rb_uv_addr_consumer)
                begin
                    is_rb_uv_full <= is_rb_uv_full + 1;
                end
                else
                begin
                    rb_uv[rb_uv_addr_producer] <= M_AXI_WDATA;
                    rb_uv_addr_producer <= rb_uv_addr_producer + 1;

                    // clear it if max depth is reached
                    if ((rb_uv_addr_producer + 1) == MEM_DDEPTH_4_UV)
                        rb_uv_addr_producer <= 0;
                end

				// if read and write are at the same address, the new data will be read
				// if (rb_uv_addr_consumer == rb_uv_addr_producer)
				// 	rb_uv_r_data <= M_AXI_WDATA;
            end
        end
    end

	// Y rob consumer
	// prepare data for running sha256 on y
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			rb_y_addr_consumer <= 0;
			prepared_r_frame_y_data[0] <= 0;
			prepared_r_frame_y_data[1] <= 0;
			prepared_r_frame_y_data[2] <= 0;
			prepared_r_frame_y_data[3] <= 0;
			current_preparing_r_frame_y_data <= 0;
			prepared_r_frame_y_data_producer <= 0;
		end
		else if ((prepared_r_frame_y_data_producer == prepared_r_frame_y_data_consumer) && (rb_y_addr_consumer == rb_y_addr_consumer_receipt))
		begin
			prepared_r_frame_y_data[current_preparing_r_frame_y_data] <= rb_y_r_data;

			// update y rob consumer
			rb_y_addr_consumer <= rb_y_addr_consumer + 1;
			// clear it if max depth is reached
			if ((rb_y_addr_consumer + 1) == MEM_DDEPTH_4_Y)
					rb_y_addr_consumer <= 0;

			// check if we have fully prepared the data
			if (current_preparing_r_frame_y_data == 3)
			begin
				current_preparing_r_frame_y_data <= 0;

				// update sha256 prepared data consumer
				prepared_r_frame_y_data_producer <= prepared_r_frame_y_data_producer + 1;
			end
			current_preparing_r_frame_y_data <= current_preparing_r_frame_y_data + 1;
		end
	end

	// UV rob consumer
	// prepare data for running sha256 on uv
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			rb_uv_addr_consumer <= 0;
			prepared_r_frame_uv_data[0] <= 0;
			prepared_r_frame_uv_data[1] <= 0;
			prepared_r_frame_uv_data[2] <= 0;
			prepared_r_frame_uv_data[3] <= 0;
			current_preparing_r_frame_uv_data <= 0;
			prepared_r_frame_uv_data_producer <= 0;
		end
		else if ((prepared_r_frame_uv_data_producer == prepared_r_frame_uv_data_consumer) && (rb_uv_addr_consumer == rb_uv_addr_consumer_receipt))
		begin
			prepared_r_frame_uv_data[current_preparing_r_frame_uv_data] <= rb_uv_r_data;

			// update uv rob consumer
			rb_uv_addr_consumer <= rb_uv_addr_consumer + 1;
			// clear it if max depth is reached
			if ((rb_uv_addr_consumer + 1) == MEM_DDEPTH_4_UV)
					rb_uv_addr_consumer <= 0;

			// check if we have fully prepared the data
			if (current_preparing_r_frame_uv_data == 3)
			begin
				current_preparing_r_frame_uv_data <= 0;

				// update sha256 prepared data consumer
				prepared_r_frame_uv_data_producer <= prepared_r_frame_uv_data_producer + 1;
			end
			current_preparing_r_frame_uv_data <= current_preparing_r_frame_uv_data + 1;
		end
	end

	// read final hash of sha256 r
	// control rst of sha256 r
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			sha256_rst_counter <= 0;
			sha256_digest_reg_y       <= 256'h0;
			sha256_digest_reg_uv       <= 256'h0;
			is_hash_ready_to_be_written_y <= 0;
			is_hash_ready_to_be_written_uv <= 0;
		end
		else if (sha256_rst_signal)
		begin
			sha256_rst_counter <= sha256_rst_counter - 1;
			is_hash_ready_to_be_written_y <= 0;
			is_hash_ready_to_be_written_uv <= 0;

			// hold ready_to_be_written for 2 cycles
			// if (sha256_rst_counter == (SHA256_RST_NUM_OF_CLOCKS - 1))
			// begin
			// 	is_hash_ready_to_be_written_y <= 0;
			// 	is_hash_ready_to_be_written_uv <= 0;
			// end
		end
		else if (is_hashing_completed_y && is_hashing_completed_uv && (!sha256_stall_trigger_wire_y) && (!sha256_stall_trigger_wire_uv) && sha256_core_digest_valid_y_reg && sha256_core_digest_valid_uv_reg && (!sha256_rst_counter))
		begin
			// write hash to register
			sha256_digest_reg_y <= sha256_core_digest_y;
			sha256_digest_reg_uv <= sha256_core_digest_uv;

			// init rst
			sha256_rst_counter <= SHA256_RST_NUM_OF_CLOCKS;

			// set hash ready to be written
			is_hash_ready_to_be_written_y <= 1;
			is_hash_ready_to_be_written_uv <= 1;
		end
	end
	
	// run sha256 for y
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal || sha256_rst_signal)
		begin
			for (i_y = 0 ; i_y < 16 ; i_y = i_y + 1)
				sha256_block_reg_y[i_y] <= 32'h0;
			sha256_init_reg_y         <= 0;
			sha256_next_reg_y         <= 0;
			sha256_init_next_just_set_reg_y <= 0;
			sha256_init_next_reg_reset_counter_y <= 0;
			sha256_hash_step_reg_y <= 0;
			is_hashing_completed_y <= 0;

			// do not reset consumer when resetting sha256 y
			// maybe we can reset it; it is guaranteed that the total number of prepared
			// data is even, so we can reset it to 0
			// if (!sha256_rst_signal)
			// 	prepared_r_frame_y_data_consumer <= 0;
			prepared_r_frame_y_data_consumer <= 0;

			current_hashing_r_frame_y_total_size_in_bytes <= 0;
            sha256_error_reg_y <= 0;
			sha256_core_digest_valid_y_reg <= 0;
		end
		else
		begin
			sha256_core_digest_valid_y_reg <= sha256_core_digest_valid_y;

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
				// if (is_prepared_r_frame_y_data_ready && (current_hashing_r_frame_y_total_size_in_bytes < R_FRAME_Y_SIZE_IN_BYTES))
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
				else if ((current_hashing_r_frame_y_total_size_in_bytes >= R_FRAME_Y_SIZE_IN_BYTES) && (!is_hashing_completed_y))    // : done with a frame
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
						sha256_block_reg_y[14] <= sha256_final_size_4_y_be[0:31];
						sha256_block_reg_y[15] <= sha256_final_size_4_y_be[32:63];
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
		if ((!S_AXI_ARESETN) || user_reset_signal || sha256_rst_signal)
		begin
			for (i_uv = 0 ; i_uv < 16 ; i_uv = i_uv + 1)
				sha256_block_reg_uv[i_uv] <= 32'h0;
			sha256_init_reg_uv         <= 0;
			sha256_next_reg_uv         <= 0;
			sha256_init_next_just_set_reg_uv <= 0;
			sha256_init_next_reg_reset_counter_uv <= 0;
			sha256_hash_step_reg_uv <= 0;
			is_hashing_completed_uv <= 0;

			// do not reset consumer when resetting sha256 uv
			// maybe we can reset it; it is guaranteed that the total number of prepared
			// data is even, so we can reset it to 0
			// if (!sha256_rst_signal)
			// 	prepared_r_frame_uv_data_consumer <= 0;
			prepared_r_frame_uv_data_consumer <= 0;

			current_hashing_r_frame_uv_total_size_in_bytes <= 0;
            sha256_error_reg_uv <= 0;
			sha256_core_digest_valid_uv_reg <= 0;
		end
		else
		begin
			sha256_core_digest_valid_uv_reg <= sha256_core_digest_valid_uv;

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
				// if (is_prepared_r_frame_uv_data_ready && (current_hashing_r_frame_uv_total_size_in_bytes < R_FRAME_UV_SIZE_IN_BYTES))
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
				else if ((current_hashing_r_frame_uv_total_size_in_bytes >= R_FRAME_UV_SIZE_IN_BYTES) && (!is_hashing_completed_uv))    // : done with a frame
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
						sha256_block_reg_uv[14] <= sha256_final_size_4_uv_be[0:31];
						sha256_block_reg_uv[15] <= sha256_final_size_4_uv_be[32:63];
					end

					sha256_next_reg_uv <= 1;
					sha256_init_next_just_set_reg_uv <= 1;
					is_hashing_completed_uv <= 1;
				end
			end
		end
	end

	// H Y rb producer
    always @(posedge S_AXI_ACLK)
    begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			rb_h_4_y_addr_producer <= 0;
			remaining_num_of_writes_for_hash_y <= 0;
			rb_h_4_y_r_data <= 0;
			rb_h_4_addr_consumer_receipt_y <= 1;
		end
		else if (rb_h_4_y_en_wire)
		begin
            // handle read
            if (rb_h_4_addr_consumer != rb_h_4_y_addr_producer)
            begin
                rb_h_4_y_r_data <= rb_h_4_y[rb_h_4_addr_consumer];
                rb_h_4_addr_consumer_receipt_y <= rb_h_4_addr_consumer;
            end
			// rb_h_4_y_r_data <= rb_h_4_y[DEBUG_MEM_R_ADDR];

			// check if we can write hash in next cycle
			if ((!remaining_num_of_writes_for_hash_y) && is_hash_ready_to_be_written_y)
				remaining_num_of_writes_for_hash_y <= SHA256_NUM_OF_CYCLES_NEEDED_4_URAM_W;

            // handle write
            if (rb_h_4_y_wea_wire)
            begin
                rb_h_4_y[rb_h_4_y_addr_producer] <= sha256_digest_reg_y[(SHA256_NUM_OF_CYCLES_NEEDED_4_URAM_W - remaining_num_of_writes_for_hash_y) * MEM_DWIDTH +: MEM_DWIDTH];
				remaining_num_of_writes_for_hash_y <= remaining_num_of_writes_for_hash_y - 1;

				rb_h_4_y_addr_producer <= rb_h_4_y_addr_producer + 1;
                // check if rb_h_y is full
				if ((rb_h_4_y_addr_producer + 1) == rb_h_4_addr_consumer)
					is_rb_h_4_y_full <= is_rb_h_4_y_full + 1;
				// clear it if max depth is reached
				if ((rb_h_4_y_addr_producer + 1) == MEM_DDEPTH_4_H)
					rb_h_4_y_addr_producer <= 0;
            end
		end
    end

	// H UV rb producer
    always @(posedge S_AXI_ACLK)
    begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			rb_h_4_uv_addr_producer <= 0;
			remaining_num_of_writes_for_hash_uv <= 0;
			rb_h_4_uv_r_data <= 0;
			rb_h_4_addr_consumer_receipt_uv <= 1;
		end
		else if (rb_h_4_uv_en_wire)
		begin
            // handle read
            if (rb_h_4_addr_consumer != rb_h_4_uv_addr_producer)
            begin
                rb_h_4_uv_r_data <= rb_h_4_uv[rb_h_4_addr_consumer];
                rb_h_4_addr_consumer_receipt_uv <= rb_h_4_addr_consumer;
            end
			// rb_h_4_uv_r_data <= rb_h_4_uv[DEBUG_MEM_R_ADDR];

			// check if we can write hash in next cycle
			if ((!remaining_num_of_writes_for_hash_uv) && is_hash_ready_to_be_written_uv)
				remaining_num_of_writes_for_hash_uv <= SHA256_NUM_OF_CYCLES_NEEDED_4_URAM_W;

            // handle write
            if (rb_h_4_uv_wea_wire)
            begin
                rb_h_4_uv[rb_h_4_uv_addr_producer] <= sha256_digest_reg_uv[(SHA256_NUM_OF_CYCLES_NEEDED_4_URAM_W - remaining_num_of_writes_for_hash_uv) * MEM_DWIDTH +: MEM_DWIDTH];
				remaining_num_of_writes_for_hash_uv <= remaining_num_of_writes_for_hash_uv - 1;

				rb_h_4_uv_addr_producer <= rb_h_4_uv_addr_producer + 1;
                // check if rb_h_y is full
				if ((rb_h_4_uv_addr_producer + 1) == rb_h_4_addr_consumer)
					is_rb_h_4_uv_full <= is_rb_h_4_uv_full + 1;
				// clear it if max depth is reached
				if ((rb_h_4_uv_addr_producer + 1) == MEM_DDEPTH_4_H)
					rb_h_4_uv_addr_producer <= 0;
            end
		end
    end

	// H Y rb consumer
	// H UV rb consumer
	always @(posedge S_AXI_ACLK)
	begin
		if ((!S_AXI_ARESETN) || user_reset_signal)
		begin
			rb_h_4_addr_consumer <= 0;
			i_4_reading_verification_hash <= 0;
			init_indicator_4_verification <= 0;
            counter_4_repeating_first_frame <= 0;
			sha256_digest_verification_reg_y <= 0;
			sha256_digest_verification_reg_uv <= 0;

            // for (i_for_debug_y_frame_hashes = 0; i_for_debug_y_frame_hashes < 32; i_for_debug_y_frame_hashes = i_for_debug_y_frame_hashes + 1)
            //     debug_y_frame_hashes[i_for_debug_y_frame_hashes] <= 0;
            // i_for_debug_y_frame_hashes <= 0;
            // debug_y_frame_hashes_refresh_n <= 0;
		end
		else if (!init_indicator_4_verification)
		begin
			if ((i_4_reading_verification_hash < 2) && (rb_h_4_addr_consumer == rb_h_4_addr_consumer_receipt_y) && (rb_h_4_addr_consumer == rb_h_4_addr_consumer_receipt_uv))
			begin
				sha256_digest_verification_reg_y[i_4_reading_verification_hash * MEM_DWIDTH +: MEM_DWIDTH] <= rb_h_4_y_r_data;
				sha256_digest_verification_reg_uv[i_4_reading_verification_hash * MEM_DWIDTH +: MEM_DWIDTH] <= rb_h_4_uv_r_data;
				i_4_reading_verification_hash <= i_4_reading_verification_hash + 1;
				
				rb_h_4_addr_consumer <= rb_h_4_addr_consumer + 1;
				// clear it if max depth is reached
				if ((rb_h_4_addr_consumer + 1) == MEM_DDEPTH_4_H)
					rb_h_4_addr_consumer <= 0;
			end
			else if (i_4_reading_verification_hash == 2)
			begin
				init_indicator_4_verification <= 1;

                // debug
                // if (i_for_debug_y_frame_hashes < 32)
                // begin
                //     debug_y_frame_hashes[i_for_debug_y_frame_hashes] <= sha256_digest_verification_reg_y[31:0];
                //     i_for_debug_y_frame_hashes <= i_for_debug_y_frame_hashes + 1;

                //     if ((i_for_debug_y_frame_hashes == 31) && (!debug_y_frame_hashes_refresh_n))
                //         i_for_debug_y_frame_hashes <= 0;
                // end
			end
		end
		else if (init_indicator_4_verification && can_proceed_showing_new_hash)
		begin
            // debug
            // if (ERROR_INDICATOR)
            //     debug_y_frame_hashes_refresh_n <= 1;

            if (counter_4_repeating_first_frame == NUM_OF_FRAMES_TO_REPEAT)
            begin
                i_4_reading_verification_hash <= 0;
                init_indicator_4_verification <= 0;
            end
            else
            begin
                counter_4_repeating_first_frame <= counter_4_repeating_first_frame + 1;
            end
		end
	end

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
		slave_wready[NS-1:0]  = (~M_AXI_WVALID | M_AXI_WREADY);
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
			always @(posedge  S_AXI_ACLK)
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
		// }}}

		//
		always @(*)
		if (!swgrant[M])
			axi_bready = 1;
		else
			axi_bready = bskd_ready[swindex[M]];

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