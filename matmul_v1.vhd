library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity matmul_v1_0 is
	generic (
		-- Users to add parameters here
--        BRAM_DATA_WIDTH	: integer	:= 8;
    BRAM_ADDR_WIDTH	: integer	:= 12;
		-- User parameters ends
		-- Do not modify the parameters beyond this line


		-- Parameters of Axi Slave Bus Interface S00_AXI
		C_S00_AXI_DATA_WIDTH	: integer	:= 32;
		C_S00_AXI_ADDR_WIDTH	: integer	:= 5; -- address update

		-- Parameters of Axi Slave Bus Interface S00_AXIS
		WEIGHT_TDATA_WIDTH	: integer	:= 128;

		-- Parameters of Axi Master Bus Interface M00_AXIS
		OUTPUT_TDATA_WIDTH	: integer	:= 64
	);
	port (
		-- Users to add ports here
    addra : out std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
    clka : out std_logic;
    dina : out std_logic_vector(127 downto 0);
    douta : in std_logic_vector(127 downto 0);
    ena : out std_logic;
    rsta : out std_logic;
    wea : out std_logic_vector(15 downto 0);
		-- User ports ends
		-- Do not modify the ports beyond this line


		-- Ports of Axi Slave Bus Interface S00_AXI
		s00_axi_aclk	: in std_logic;
		s00_axi_aresetn	: in std_logic;
		s00_axi_awaddr	: in std_logic_vector(C_S00_AXI_ADDR_WIDTH-1 downto 0);
		s00_axi_awprot	: in std_logic_vector(2 downto 0);
		s00_axi_awvalid	: in std_logic;
		s00_axi_awready	: out std_logic;
		s00_axi_wdata	: in std_logic_vector(C_S00_AXI_DATA_WIDTH-1 downto 0);
		s00_axi_wstrb	: in std_logic_vector((C_S00_AXI_DATA_WIDTH/8)-1 downto 0);
		s00_axi_wvalid	: in std_logic;
		s00_axi_wready	: out std_logic;
		s00_axi_bresp	: out std_logic_vector(1 downto 0);
		s00_axi_bvalid	: out std_logic;
		s00_axi_bready	: in std_logic;
		s00_axi_araddr	: in std_logic_vector(C_S00_AXI_ADDR_WIDTH-1 downto 0);
		s00_axi_arprot	: in std_logic_vector(2 downto 0);
		s00_axi_arvalid	: in std_logic;
		s00_axi_arready	: out std_logic;
		s00_axi_rdata	: out std_logic_vector(C_S00_AXI_DATA_WIDTH-1 downto 0);
		s00_axi_rresp	: out std_logic_vector(1 downto 0);
		s00_axi_rvalid	: out std_logic;
		s00_axi_rready	: in std_logic;

		-- Ports of Axi Slave Bus Interface S00_AXIS
		axis_aclk	: in std_logic;
		axis_aresetn	: in std_logic;
		s00_axis_tready	: out std_logic;
		s00_axis_tdata	: in std_logic_vector(WEIGHT_TDATA_WIDTH-1 downto 0);
		s00_axis_tstrb	: in std_logic_vector((WEIGHT_TDATA_WIDTH/8)-1 downto 0);
		s00_axis_tlast	: in std_logic;
		s00_axis_tvalid	: in std_logic;
	
		-- Ports of Axi Master Bus Interface M00_AXIS
--		m00_axis_aclk	: in std_logic;
--		m00_axis_aresetn	: in std_logic;
		m00_axis_tvalid	: out std_logic;
		m00_axis_tdata	: out std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0);
		m00_axis_tstrb	: out std_logic_vector((OUTPUT_TDATA_WIDTH/8)-1 downto 0);
		m00_axis_tlast	: out std_logic;
		m00_axis_tready	: in std_logic
	);
end matmul_v1_0;

architecture arch_imp of matmul_v1_0 is

	-- component declaration
	component matmul_v1_0_S00_AXI is
		generic (
		C_S_AXI_DATA_WIDTH	: integer	:= 32;
		C_S_AXI_ADDR_WIDTH	: integer	:= 5
		);
		port (
    vec_len : out unsigned(15 downto 0);
    
		S_AXI_ACLK	: in std_logic;
		S_AXI_ARESETN	: in std_logic;
		S_AXI_AWADDR	: in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
		S_AXI_AWPROT	: in std_logic_vector(2 downto 0);
		S_AXI_AWVALID	: in std_logic;
		S_AXI_AWREADY	: out std_logic;
		S_AXI_WDATA	: in std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		S_AXI_WSTRB	: in std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
		S_AXI_WVALID	: in std_logic;
		S_AXI_WREADY	: out std_logic;
		S_AXI_BRESP	: out std_logic_vector(1 downto 0);
		S_AXI_BVALID	: out std_logic;
		S_AXI_BREADY	: in std_logic;
		S_AXI_ARADDR	: in std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
		S_AXI_ARPROT	: in std_logic_vector(2 downto 0);
		S_AXI_ARVALID	: in std_logic;
		S_AXI_ARREADY	: out std_logic;
		S_AXI_RDATA	: out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
		S_AXI_RRESP	: out std_logic_vector(1 downto 0);
		S_AXI_RVALID	: out std_logic;
		S_AXI_RREADY	: in std_logic
		);
	end component matmul_v1_0_S00_AXI;
	
  component matmul_manager is
    generic (
      WEIGHT_TDATA_WIDTH	: integer	:= 128;
      OUTPUT_TDATA_WIDTH	: integer	:= 64;
      BRAM_ADDR_WIDTH	: integer	:= 12
    );
    Port (
      length: in unsigned(15 downto 0);
      -- Ports of Axi Slave Bus Interface S00_AXIS
      s00_axis_aclk	: in std_logic;
      s00_axis_aresetn	: in std_logic;
      s00_axis_tready	: out std_logic;
      s00_axis_tdata	: in std_logic_vector(WEIGHT_TDATA_WIDTH-1 downto 0);
      s00_axis_tlast	: in std_logic;
      s00_axis_tvalid	: in std_logic;
      
      -- Ports of Axi Master Bus Interface M00_AXIS
--      m00_axis_aclk	: in std_logic;
--      m00_axis_aresetn	: in std_logic;
      m00_axis_tvalid	: out std_logic;
      m00_axis_tdata	: out std_logic_vector(OUTPUT_TDATA_WIDTH-1 downto 0);
      m00_axis_tlast	: out std_logic;
      m00_axis_tready	: in std_logic;
		
      bram_din: in std_logic_vector(127 downto 0);
      bram_addr: out std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0);
      bram_en: out std_logic
    );
  end component;

  signal vec_len : unsigned(15 downto 0) := x"0000";
--  signal bram_addr : std_logic_vector(BRAM_ADDR_WIDTH-1 downto 0) := (others => '0');
--  signal bram_8bit : std_logic_vector(7 downto 0) := x"00";
begin
--bram_8bit <= douta(7 downto 0) when bram_addr(1 downto 0) = "00" else
--             douta(15 downto 8) when bram_addr(1 downto 0) = "01" else
--             douta(23 downto 16) when bram_addr(1 downto 0) = "10" else
--             douta(31 downto 24);
--addra <= bram_addr;
-- Instantiation of Axi Bus Interface S00_AXI
axilite : matmul_v1_0_S00_AXI
	generic map (
		C_S_AXI_DATA_WIDTH	=> C_S00_AXI_DATA_WIDTH,
		C_S_AXI_ADDR_WIDTH	=> C_S00_AXI_ADDR_WIDTH
	)
	port map (
	  vec_len => vec_len,
		S_AXI_ACLK	=> s00_axi_aclk,
		S_AXI_ARESETN	=> s00_axi_aresetn,
		S_AXI_AWADDR	=> s00_axi_awaddr,
		S_AXI_AWPROT	=> s00_axi_awprot,
		S_AXI_AWVALID	=> s00_axi_awvalid,
		S_AXI_AWREADY	=> s00_axi_awready,
		S_AXI_WDATA	=> s00_axi_wdata,
		S_AXI_WSTRB	=> s00_axi_wstrb,
		S_AXI_WVALID	=> s00_axi_wvalid,
		S_AXI_WREADY	=> s00_axi_wready,
		S_AXI_BRESP	=> s00_axi_bresp,
		S_AXI_BVALID	=> s00_axi_bvalid,
		S_AXI_BREADY	=> s00_axi_bready,
		S_AXI_ARADDR	=> s00_axi_araddr,
		S_AXI_ARPROT	=> s00_axi_arprot,
		S_AXI_ARVALID	=> s00_axi_arvalid,
		S_AXI_ARREADY	=> s00_axi_arready,
		S_AXI_RDATA	=> s00_axi_rdata,
		S_AXI_RRESP	=> s00_axi_rresp,
		S_AXI_RVALID	=> s00_axi_rvalid,
		S_AXI_RREADY	=> s00_axi_rready
	);
	
	
matmul_inst : matmul_manager
  generic map (
    WEIGHT_TDATA_WIDTH => WEIGHT_TDATA_WIDTH,
    OUTPUT_TDATA_WIDTH => OUTPUT_TDATA_WIDTH
  )
  port map (
    length => vec_len,
    -- Ports of Axi Slave Bus Interface S00_AXIS
    s00_axis_aclk => axis_aclk,
    s00_axis_aresetn => axis_aresetn,
    s00_axis_tready => s00_axis_tready,
    s00_axis_tdata => s00_axis_tdata,
    s00_axis_tlast => s00_axis_tlast,
    s00_axis_tvalid => s00_axis_tvalid,
    -- Ports of Axi Master Bus Interface M00_AXIS
    m00_axis_tvalid => m00_axis_tvalid,
    m00_axis_tdata => m00_axis_tdata,
    m00_axis_tlast => m00_axis_tlast,
    m00_axis_tready => m00_axis_tready,
    bram_din => douta,
    bram_addr => addra,
    bram_en => ena
    );

m00_axis_tstrb <= (others => '1');
clka <= s00_axi_aclk;
dina <= (others => '0');
rsta <='0';
wea <= (others => '0');

end arch_imp;