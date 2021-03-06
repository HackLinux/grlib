------------------------------------------------------------------------------
--  This file is a part of the GRLIB VHDL IP LIBRARY
--  Copyright (C) 2003 - 2008, Gaisler Research
--  Copyright (C) 2008 - 2013, Aeroflex Gaisler
--
--  This program is free software; you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation; either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program; if not, write to the Free Software
--  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA 
-----------------------------------------------------------------------------
-- Entity:  ddrsp16a
-- File:    ddrsp16a.vhd
-- Author:  Jiri Gaisler - Gaisler Research
-- Description: 16-bit DDR266 memory controller with asych AHB interface
------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
library grlib;
use grlib.amba.all;
use grlib.stdlib.all;
library gaisler;
use grlib.devices.all;
use gaisler.memctrl.all;
library techmap;
use techmap.gencomp.all;

entity ddrsp16a is
  generic (
    memtech : integer := 0;
    hindex  : integer := 0;
    haddr   : integer := 0;
    hmask   : integer := 16#f00#;
    ioaddr  : integer := 16#000#;
    iomask  : integer := 16#fff#;
    MHz     : integer := 100;
    col     : integer := 9; 
    Mbyte   : integer := 8; 
    fast    : integer := 0; 
    pwron   : integer := 0;
    oepol   : integer := 0;
    mobile  : integer := 0;
    confapi : integer := 0;
    conf0   : integer := 0;
    conf1   : integer := 0;
    regoutput : integer := 0
  );
  port (
    rst     : in  std_ulogic;
    clk_ddr : in  std_ulogic;
    clk_ahb : in  std_ulogic;
    clkread : in  std_ulogic;
    ahbsi   : in  ahb_slv_in_type;
    ahbso   : out ahb_slv_out_type;
    sdi     : in  sdctrl_in_type;
    sdo     : out sdctrl_out_type
  );
end; 

architecture rtl of ddrsp16a is

constant REVISION  : integer := 0;

constant CMD_PRE  : std_logic_vector(2 downto 0) := "010";
constant CMD_REF  : std_logic_vector(2 downto 0) := "100";
constant CMD_LMR  : std_logic_vector(2 downto 0) := "110";
constant CMD_EMR  : std_logic_vector(2 downto 0) := "111";

constant PM_PD    : std_logic_vector(2 downto 0) := "001";
constant PM_SR    : std_logic_vector(2 downto 0) := "010";
constant PM_CKS   : std_logic_vector(2 downto 0) := "100";
constant PM_DPD   : std_logic_vector(2 downto 0) := "101";

constant abuf : integer := 6;
constant hconfig : ahb_config_type := (
  0 => ahb_device_reg ( VENDOR_GAISLER, GAISLER_DDRSP, 0, REVISION, 0),
  4 => ahb_membar(haddr, '1', '1', hmask),
  5 => ahb_iobar(ioaddr, iomask),
  others => zero32);

type mcycletype is (midle, active, ext, leadout);
type ahb_state_type is (midle, rhold, dread, dwrite, whold1, whold2);
type sdcycletype is (act1, act2, act3, rd1, rd2, rd2a, rd3, rd3a, rd4, rd5, rd6, rd7, rd8, 
                     wr1, wr2, wr3, wr4a, wr4, wr5, sidle, ioreg1, ioreg2,
                     sref, cks, pd, dpd, srr1, srr2, srr3);
type icycletype is (iidle, pre, ref1, ref2, emode, lmode, finish);

-- sdram configuration register

type sdram_cfg_type is record
  command          : std_logic_vector(2 downto 0);
  csize            : std_logic_vector(1 downto 0);
  bsize            : std_logic_vector(2 downto 0);
  trcd             : std_ulogic;  -- tCD : 2/3 clock cycles
  trfc             : std_logic_vector(2 downto 0);
  trp              : std_ulogic;  -- precharge to activate: 2/3 clock cycles
  refresh          : std_logic_vector(11 downto 0);
  renable          : std_ulogic;
  dllrst           : std_ulogic;
  refon            : std_ulogic;
  cke              : std_ulogic;
  pasr        : std_logic_vector(5 downto 0); -- pasr(2:0) (pasr(5:3) used to detect update)
  tcsr        : std_logic_vector(3 downto 0); -- tcrs(1:0) (tcrs(3:2) used to detect update)
  ds          : std_logic_vector(5 downto 0); -- ds(1:0) (ds(3:2) used to detect update)
  pmode       : std_logic_vector(2 downto 0); -- Power-Saving mode
  mobileen    : std_logic_vector(1 downto 0); -- Mobile SD support, Mobile SD enabled
  txsr        : std_logic_vector(3 downto 0); -- Exit Self Refresh timing
  txp         : std_logic; -- Exit Power-Down timing
  tcke        : std_logic; -- Clock enable timing
  cl          : std_logic; -- CAS latency 2/3 (0/1)
  conf        : std_logic_vector(63 downto 0); -- PHY control
end record;

type access_param is record
  haddr         : std_logic_vector(31 downto 0);
  size          : std_logic_vector(1 downto 0);
  hwrite        : std_ulogic;
  hio           : std_ulogic;
end record;
-- local registers

type ahb_reg_type is record
  hready        : std_ulogic;
  hsel          : std_ulogic;
  hio           : std_ulogic;
  startsd       : std_ulogic;
  ready         : std_ulogic;
  ready2        : std_ulogic;
  write         : std_ulogic;
  state         : ahb_state_type;
  haddr         : std_logic_vector(31 downto 0);
  hrdata        : std_logic_vector(31 downto 0);
  hwrite        : std_ulogic;
  htrans        : std_logic_vector(1 downto 0);
  hresp         : std_logic_vector(1 downto 0);
  raddr         : std_logic_vector(abuf-1 downto 0);
  size          : std_logic_vector(1 downto 0);
  acc           : access_param;
end record;

type ddr_reg_type is record
  startsd       : std_ulogic;
  startsdold    : std_ulogic;
  burst         : std_ulogic;
  hready        : std_ulogic;
  bdrive        : std_ulogic;
  qdrive        : std_ulogic;
  nbdrive       : std_ulogic; 
  mstate        : mcycletype;
  sdstate       : sdcycletype;
  cmstate       : mcycletype;
  istate        : icycletype;
  trfc          : std_logic_vector(3 downto 0); -- Extend trfc for mobile ddr
  refresh       : std_logic_vector(11 downto 0);
  sdcsn         : std_logic_vector(1  downto 0);
  sdwen         : std_ulogic;
  rasn          : std_ulogic;
  casn          : std_ulogic;
  dqm           : std_logic_vector(3 downto 0);
  dqm_dly       : std_logic_vector(3 downto 0);   -- *** ??? delay ctrl
  wdata         : std_logic_vector(31 downto 0);    -- *** ??? delay ctrl
  address       : std_logic_vector(15 downto 2);  -- memory address
  ba            : std_logic_vector(1  downto 0);
  waddr         : std_logic_vector(abuf-1 downto 0);
  cfg           : sdram_cfg_type;
  idlecnt       : std_logic_vector(3 downto 0); -- Counter, 16 idle clock sycles before entering Power-Saving mode
  ck            : std_logic_vector(2 downto 0); -- Clock stop signal, 0 = clock stoped, 1 = clock running
  txp           : std_logic;
  tcke          : std_logic;
  sref_tmpcom   : std_logic_vector(2 downto 0); -- Save SD command when exit sref
  extdqs        : std_logic; -- Extend dqs postamble
  sdo_bdrive    : std_logic; -- *** ??? delay ctrl
  sdo_qdrive    : std_logic; -- *** ??? delay ctrl
  ck_dly        : std_logic_vector(2 downto 0); -- *** ??? delay ctrl
  cke_dly       : std_logic; -- *** ??? delay ctrl
end record;

signal vcc, rwrite : std_ulogic;
signal r, ri : ddr_reg_type;
signal ra, rai : ahb_reg_type;
signal rdata, wdata, rwdata, rbdrive, ribdrive : std_logic_vector(31 downto 0);
signal waddr2 : std_logic_vector(abuf-1 downto 0);
signal ddr_rst : std_logic;
signal ddr_rst_gen  : std_logic_vector(3 downto 0);
signal hwdata : std_logic_vector(31 downto 0);

attribute keep                     : boolean;
attribute syn_keep                 : boolean;
attribute syn_preserve : boolean;

attribute syn_preserve of rbdrive : signal is true; 
attribute keep of rwdata : signal is true; 
attribute syn_keep of rwdata : signal is true; 
attribute syn_preserve of rwdata : signal is true; 

begin

  vcc <= '1';

  ddr_rst <= (ddr_rst_gen(3) and ddr_rst_gen(2) and ddr_rst_gen(1) and rst); -- Reset signal in DDR clock domain
  
  ahb_ctrl : process(rst, ahbsi, r, ra, rdata)
  variable v       : ahb_reg_type;		-- local variables for registers
  variable startsd : std_ulogic;
  begin

    v := ra; v.hrdata := rdata; v.hresp := HRESP_OKAY; 
    v.write := '0';

    v.ready := not (ra.startsd xor r.startsdold);
    v.ready2 := ra.ready;
    if ((ahbsi.hready and ahbsi.hsel(hindex)) = '1') then
      v.htrans := ahbsi.htrans; v.haddr := ahbsi.haddr;
      v.size := ahbsi.hsize(1 downto 0); v.hwrite := ahbsi.hwrite;
      if ahbsi.htrans(1) = '1' then
        v.hio := ahbsi.hmbsel(1);
        v.hsel := '1'; v.hready := '0';
      end if;
    end if;

    if ahbsi.hready = '1' then v.hsel := ahbsi.hsel(hindex); end if;
--    if (ra.hsel and ra.hio and not ra.hready) = '1' then v.hready := '1'; end if;

    case ra.state is
    when midle =>
      if ((v.hsel and v.htrans(1)) = '1') then
        if v.hwrite = '0' then 
          v.state := rhold; v.startsd := not ra.startsd;
        else v.state := dwrite; v.hready := '1'; v.write := '1'; end if;
      end if;
      v.raddr := ra.haddr(7 downto 2);
      v.ready := '0'; v.ready2 := '0';
      if ahbsi.hready = '1' then
        v.acc := (v.haddr, v.size, v.hwrite, v.hio);
      end if;
    when rhold =>
      v.raddr := ra.haddr(7 downto 2);
      if ra.ready2 = '1' then
        v.state := dread; v.hready := '1'; v.raddr := ra.raddr + 1;
      end if;
    when dread =>
      v.raddr := ra.raddr + 1; v.hready := '1';
      if ((v.hsel and v.htrans(1) and v.htrans(0)) = '0') or 
         (ra.raddr(2 downto 0) = "000")
--      then v.state := midle; v.hready := '0'; end if;
      then 
        v.state := midle; v.hready := not (v.hsel and v.htrans(1));
        if (v.hsel and v.htrans(1) and v.hwrite) = '1' then 
          v.state := dwrite; v.hready := '1'; v.write := '1';
          v.ready := '0'; v.ready2 := '0';
        end if;
      end if;
      v.acc := (v.haddr, v.size, v.hwrite, v.hio);
    when dwrite => 
      v.raddr := ra.haddr(7 downto 2); v.write := '1'; v.hready := '1';
      if ((v.hsel and v.htrans(1) and v.htrans(0)) = '0') or 
         ((ra.haddr(4 downto 2) = "111") and (ra.write = '1'))
      then
        v.startsd := not ra.startsd; v.state := whold1; 
        v.write := '0'; v.hready := not (v.hsel and v.htrans(1));
--        v.write := '0'; v.hready := '0';
      end if;
    when whold1 =>
      v.state := whold2; v.ready := '0';
    when whold2 =>
      if ra.ready = '1' then
        v.state := midle; v.acc := (v.haddr, v.size, v.hwrite, v.hio);
      end if;
    end case;

    if (ahbsi.hready and ahbsi.hsel(hindex) ) = '1' then
      if ahbsi.htrans(1) = '0' then v.hready := '1'; end if;
    end if;

    if rst = '0' then
      v.hsel      := '0';
      v.hready    := '1';
      v.state     := midle;
      v.startsd   := '0';
      v.hio       := '0';
    end if;

    rai <= v;
    ahbso.hready  <= ra.hready;
    ahbso.hresp   <= ra.hresp;
    ahbso.hrdata  <= ahbdrivedata(ra.hrdata);

  end process;

  ddr_ctrl : process(ddr_rst, r, ra, sdi, rbdrive, wdata)
  variable v       : ddr_reg_type;		-- local variables for registers
  variable startsd : std_ulogic;
  variable dataout : std_logic_vector(31 downto 0); -- data from memory
  variable dqm     : std_logic_vector(3 downto 0);
  variable raddr   : std_logic_vector(13 downto 0);
  variable adec    : std_ulogic;
  variable rams    : std_logic_vector(1 downto 0);
  variable ba      : std_logic_vector(1 downto 0);
  variable haddr   : std_logic_vector(31 downto 0);
  variable hwrite  : std_ulogic;
  variable htrans  : std_logic_vector(1 downto 0);
  variable hready  : std_ulogic;
  variable vbdrive : std_logic_vector(31 downto 0);
  variable bdrive  : std_ulogic; 
  variable writecfg: std_ulogic; 
  variable regsd   : std_logic_vector(31 downto 0);   -- data from registers
  variable readdata: std_logic_vector(31 downto 0);   -- data from DDR
  variable arefresh: std_logic;
  begin

-- Variable default settings to avoid latches

    v := r; v.hready := '0'; writecfg := '0'; vbdrive := rbdrive; 
    readdata := sdi.data(31 downto 0); 
    v.qdrive :='0'; v.txp := '0'; v.tcke := '0'; arefresh := '0';
    v.wdata := wdata;                                                               -- *** ??? delay ctrl
    v.dqm_dly := r.dqm;                                                             -- *** ??? delay ctrl
    v.ck_dly := r.ck;                                                               -- *** ??? delay ctrl
    v.cke_dly := r.cfg.cke;                                                         -- *** ??? delay ctrl

    regsd := (others => '0');
    if ra.acc.haddr(4 downto 2) = "000" then
      regsd(31 downto 15) := r.cfg.refon & r.cfg.trp & r.cfg.trfc &
                             r.cfg.trcd & r.cfg.bsize & r.cfg.csize & r.cfg.command &
                             r.cfg.dllrst & r.cfg.renable & r.cfg.cke; 
      regsd(11 downto 0) := r.cfg.refresh; 
    elsif ra.acc.haddr(4 downto 2) = "001" then
      regsd(8 downto 0) := conv_std_logic_vector(MHz, 9);
      regsd(14 downto 12) := conv_std_logic_vector(1, 3);
      regsd(15) := r.cfg.mobileen(1); -- Mobile DDR support
      regsd(19 downto 16) := conv_std_logic_vector(confapi, 4);
    elsif ra.acc.haddr(4 downto 2) = "010" then
      regsd(31 downto 30) := r.cfg.mobileen(0) & r.cfg.cl; -- Mobile DDR enable
      regsd(24 downto 19) := r.cfg.tcke & r.cfg.txsr & r.cfg.txp;
      regsd(18 downto 16) := r.cfg.pmode;
      regsd( 7 downto  0) := r.cfg.ds(2 downto 0) & r.cfg.tcsr(1 downto 0) 
                             & r.cfg.pasr(2 downto 0);
    elsif ra.acc.haddr(4 downto 2) = "101" and confapi /= 0 then
      regsd(31 downto 0) := r.cfg.conf(31 downto 0);
    elsif ra.acc.haddr(4 downto 2) = "110" and confapi /= 0 then
      regsd(31 downto 0) := r.cfg.conf(63 downto 32);
    end if;


-- generate DQM from address and write size

    case ra.acc.size is
    when "00" =>
      case ra.acc.haddr(1 downto 0) is
      when "00" => dqm := "0111";
      when "01" => dqm := "1011";
      when "10" => dqm := "1101";
      when others => dqm := "1110";
      end case;
    when "01" =>
      if ra.acc.haddr(1) = '0' then dqm := "0011"; else  dqm := "1100"; end if;
    when others => dqm := "0000";
    end case;

    v.startsd := ra.startsd;

-- main FSM

    case r.mstate is
    when midle =>
      if  r.startsd = '1' then
        if (r.sdstate = sidle) and (r.cfg.command = "000") and 
           (r.cmstate = midle) 
        then 
          startsd := '1'; v.mstate := active;
        end if;
      end if;
    when others => null;
    end case;

    startsd := r.startsd xor r.startsdold;

-- generate row and column address size

    haddr := ra.acc.haddr;
    haddr(31 downto 20) := haddr(31 downto 20) and not conv_std_logic_vector(hmask, 12);

    case r.cfg.csize is
    when "00" => raddr := haddr(23 downto 10);
    when "01" => raddr := haddr(24 downto 11);
    when "10" => raddr := haddr(25 downto 12);
    when others => raddr := haddr(26 downto 13);
    end case;

-- generate bank address

    ba := genmux(r.cfg.bsize, haddr(29 downto 22)) &
          genmux(r.cfg.bsize, haddr(28 downto 21));

-- generate chip select

    adec := genmux(r.cfg.bsize, haddr(30 downto 23));

    rams := adec & not adec;

-- sdram access FSM

    if r.trfc /= "0000" then v.trfc := r.trfc - 1; end if; -- Extend trfc for mobile ddr

    if r.idlecnt /= "0000" then v.idlecnt := r.idlecnt - 1; end if;

    case r.sdstate is
    when sidle =>
      v.extdqs := '1';
      if (startsd = '1') and (r.cfg.command = "000") and (r.cmstate = midle) 
         and (r.istate = finish)
      then
        v.address := raddr; v.ba := ba;
        if ra.acc.hio = '0' then
          v.sdcsn := not rams(1 downto 0); v.rasn := '0'; v.sdstate := act1; 
        elsif ra.acc.haddr(4 downto 2) = "100" and r.cfg.mobileen(0) = '1' then v.sdstate := srr1;
        else v.sdstate := ioreg1; end if;
      elsif (r.cfg.command = "000") and (r.cmstate = midle) 
            and (r.istate = finish) and r.idlecnt = "0000" and (r.cfg.mobileen(1) = '1') then
        case r.cfg.pmode is
        when PM_SR => v.cfg.cke := '0'; v.sdstate := sref;
        when PM_CKS => v.ck := (others => '0'); v.sdstate := cks;
        when PM_PD => v.cfg.cke := '0'; v.sdstate := pd;
        when PM_DPD => v.cfg.cke := '0'; v.sdstate := dpd;
        when others =>
        end case;
        if r.cfg.pmode /= "000" then v.trfc := (r.cfg.trp and r.cfg.mobileen(1)) & r.cfg.trfc; end if; -- Extend trfc for mobile ddr 
      end if;
      v.waddr := ra.acc.haddr(7 downto 2);
    when act1 =>
      v.rasn := '1'; v.trfc := (r.cfg.trp and r.cfg.mobileen(1)) & r.cfg.trfc; -- Extend trfc for mobile ddr
      if r.cfg.trcd = '1' then v.sdstate := act2; else
        v.sdstate := act3; v.hready := ra.acc.hwrite;
      end if;
      v.waddr := ra.acc.haddr(7 downto 2);
    when act2 =>
      v.sdstate := act3; v.hready := ra.acc.hwrite;
    when act3 =>
      v.casn := '0'; 
      v.address := ra.acc.haddr(13 downto 11) & '0' & ra.acc.haddr(10 downto 2) & '0';
      v.dqm := dqm; 
      if ra.acc.hwrite = '1' then
        v.waddr := r.waddr + 1;
        v.sdstate := wr1; v.sdwen := '0'; v.bdrive := '0'; v.qdrive := '1';
        if (r.waddr /= ra.raddr) then v.hready := '1'; end if;
      else v.sdstate := rd1; end if;
    when wr1 =>
      v.sdwen := '1';  v.casn := '1';  v.qdrive := '1';
      v.waddr := r.waddr + 1;
      v.address(8 downto 3) := r.waddr;
      if (r.waddr <= ra.raddr) and (r.waddr /= "000000") and (r.hready = '1') 
      then
        v.extdqs := '0';
        v.hready := '1';
        if (r.hready = '1') and (r.waddr(1 downto 0) = "00") then
          v.sdwen := '0'; v.casn := '0'; v.extdqs := '1';
        end if;
      else
        v.sdstate := wr2;
        v.dqm := (others => '1'); --v.bdrive := '1'; 
        v.startsdold := r.startsd;
      end if;
    when wr2 =>
      v.sdstate := wr3; v.qdrive := '1';
    when wr3 =>
      v.sdstate := wr4a; v.qdrive := '1';
    when wr4a =>
      v.bdrive := '1'; 
      v.rasn := '0'; v.sdwen := '0'; v.sdstate := wr4; v.qdrive := '1';
    when wr4 =>
      v.sdcsn := "11"; v.rasn := '1'; v.sdwen := '1';  --v.qdrive := '0';
      if r.extdqs = '1' then v.qdrive := '1'; else v.qdrive := '0'; end if;
      v.sdstate := wr5;
    when wr5 =>
      v.sdstate := sidle;
      v.qdrive := '0';
      v.idlecnt := (others => '1');
    when rd1 =>
      v.casn := '1'; v.sdstate := rd7;
      if ra.acc.haddr(4 downto 2) = "011" then 
        v.casn := '0'; v.burst := '1'; v.address(5 downto 3) := "100";
      end if;
    when rd7 =>
      v.casn := '1'; v.sdstate := rd2;
      if ra.acc.haddr(4 downto 2) = "010" then 
        v.casn := '0'; v.burst := '1'; v.address(5 downto 3) := "100";
      end if;
    when rd2 =>
      --v.casn := '1'; v.sdstate := rd3;
      v.casn := '1'; 
      if regoutput = 1 then v.sdstate := rd2a; else v.sdstate := rd3; end if; -- delay if registered output
      if ra.acc.haddr(4 downto 2) = "001" then 
        v.casn := '0'; v.burst := '1'; v.address(5 downto 3) := "100";
      end if;
    when rd2a => -- delay if registered output
      v.sdstate := rd3; v.hready := '0'; v.casn := '1';
      if r.sdwen = '0' then -- ??? this cant be true ???
        v.rasn := '1'; v.sdwen := '1'; v.sdcsn := "11"; v.dqm := (others => '1');
      elsif ra.acc.haddr(4 downto 2) = "000" then 
        v.casn := '0'; v.burst := '1'; v.address(5) := '1';
        --v.waddr := v.address(8 downto 3); -- ****
      end if;
    when rd3 =>
      if r.cfg.cl = '0' then -- CL = 2
        if fast = 0 then v.startsdold := r.startsd; end if;
        v.sdstate := rd4; v.hready := '1'; v.casn := '1';
      else -- CL = 3
        v.sdstate := rd3a; v.hready := '0'; v.casn := '1';
      end if;
      if regoutput = 0 then -- done in rd2a if registered output 
        if r.sdwen = '0' then -- ??? this cant be true ???
          v.rasn := '1'; v.sdwen := '1'; v.sdcsn := "11"; v.dqm := (others => '1');
        elsif ra.acc.haddr(4 downto 2) = "000" then 
          v.casn := '0'; v.burst := '1'; v.address(5) := '1';
          --v.waddr := v.address(8 downto 3); -- ****
        end if;
      end if;
      if v.hready = '1' then v.waddr := r.waddr + 1; end if;
    when rd3a =>
      if fast = 0 then v.startsdold := r.startsd; end if;
      v.sdstate := rd4; v.hready := '1'; v.casn := '1';
      if v.hready = '1' then v.waddr := r.waddr + 1; end if;
      if (r.sdcsn /= "11") and (r.waddr(1 downto 0) = "11") and (r.burst = '1')
      then v.burst := '0'; end if;
    when rd4 =>
      v.hready := '1'; v.casn := '1';
      if (r.sdcsn /= "11") and (r.waddr(1 downto 0) = "11") and (r.burst = '1')
      then
        v.burst := '0';
      elsif (r.sdcsn = "11") or (r.waddr(1 downto 0) = "11") then
        v.dqm := (others => '1'); v.burst := '0';
        if fast /= 0 then v.startsdold := r.startsd; end if;
        if (r.sdcsn /= "11") then
          v.rasn := '0'; v.sdwen := '0'; v.sdstate := rd5;
        else
          if r.cfg.trp = '1' then v.sdstate := rd6; 
          else v.sdstate := sidle; v.idlecnt := (others => '1'); end if;
        end if;
      end if;
      if v.hready = '1' then v.waddr := r.waddr + 1; end if;
    when rd5 =>
      if r.cfg.trp = '1' then v.sdstate := rd6; 
      else v.sdstate := sidle; v.idlecnt := (others => '1'); end if;
      v.sdcsn := (others => '1'); v.rasn := '1'; v.sdwen := '1'; 
      v.dqm := (others => '1');
    when rd6 =>
      v.sdstate := sidle; v.dqm := (others => '1');
      v.idlecnt := (others => '1');
      v.sdcsn := (others => '1'); v.rasn := '1'; v.sdwen := '1';
    when ioreg1 =>
      readdata := regsd; v.sdstate := ioreg2;
      if ra.acc.hwrite = '0' then v.hready := '1'; end if;
    when ioreg2 =>
      readdata := regsd; 
      writecfg := ra.acc.hwrite; v.startsdold := r.startsd;
      case r.cfg.pmode is
      when PM_SR => v.cfg.cke := '0'; v.sdstate := sref;
      when PM_CKS => v.ck := (others => '0'); v.sdstate := cks;
      when PM_PD => v.cfg.cke := '0'; v.sdstate := pd;
      when PM_DPD => v.cfg.cke := '0'; v.sdstate := dpd;
      when others => v.sdstate := sidle; v.idlecnt := (others => '1');
      end case;
      if r.cfg.pmode /= "000" and r.cfg.cke = '1' then v.trfc := (r.cfg.trp and r.cfg.mobileen(1)) & r.cfg.trfc; end if; -- Extend trfc for mobile ddr
    when sref =>
      v.sdcsn := (others => '0'); v.rasn := '0'; v.casn := '0';
      if (startsd = '1' and (ra.acc.hio = '0' or ra.acc.haddr(4 downto 2) = "100")) 
          or (r.cfg.command /= "000") or r.cfg.pmode /= PM_SR then
        if r.trfc = "0000" then v.cfg.cke := '1'; end if;  -- Extend trfc for mobile ddr
        if r.cfg.cke = '1' then
          v.sdcsn := (others => '0'); v.rasn := '1'; v.casn := '1';
          if (r.idlecnt = "0000" and r.cfg.mobileen(0) = '1') -- 120 ns (tXSR) with NOP 
             or (r.refresh(8) = '0' and r.cfg.mobileen(0) = '0') then -- 200 clock cycles
            v.sdstate := sidle;
            v.idlecnt := (others => '1');
            v.sref_tmpcom := r.cfg.command;
            v.cfg.command := CMD_REF; 
          end if;
        else
          v.idlecnt := r.cfg.txsr;
        end if;
      elsif (startsd = '1' and ra.acc.hio = '1') then
        v.waddr := ra.acc.haddr(7 downto 2);
        v.sdstate := ioreg1;
      end if;
    when cks =>
      if (startsd = '1' and (ra.acc.hio = '0' or ra.acc.haddr(4 downto 2) = "100")) 
          or (r.cfg.command /= "000") or r.cfg.pmode /= PM_CKS then
        v.ck := (others => '1');
        v.sdstate := sidle; v.idlecnt := (others => '1');
      elsif (startsd = '1' and ra.acc.hio = '1') then
        v.waddr := ra.acc.haddr(7 downto 2);
        v.sdstate := ioreg1;
      end if;
    when pd =>
      v.tcke := '1';
      if ((startsd = '1' and (ra.acc.hio = '0' or ra.acc.haddr(4 downto 2) = "100")) 
          or (r.cfg.command /= "000") or r.cfg.pmode /= PM_PD)
          and (r.tcke = '1' or r.cfg.tcke = '0') then
        v.cfg.cke := '1'; 
        v.txp := r.cfg.cke;
        if r.cfg.cke = '1' and (r.txp = '1' or r.cfg.txp = '0') then -- 1 - 2 clock cycles 
          v.sdstate := sidle;
          v.idlecnt := (others => '1');
        end if;
      elsif startsd = '1' and ra.acc.hio = '1' and (r.tcke = '1' or r.cfg.tcke = '0') then
        v.waddr := ra.acc.haddr(7 downto 2);
        v.sdstate := ioreg1;
      end if;
    when dpd =>
      v.sdcsn := (others => '0'); v.sdwen := '0'; v.rasn := '1'; v.casn := '1';
      v.cfg.refon := '0';
      if (startsd = '1' and ra.acc.hio = '1') then
        v.waddr := ra.acc.haddr(7 downto 2);
        v.sdstate := ioreg1;
      elsif startsd = '1' then
        v.startsdold := r.startsd; -- acc all accesses
      elsif r.cfg.pmode /= PM_DPD then
        v.cfg.cke := '1';
        if r.cfg.cke = '1' then
          v.sdcsn := (others => '0'); v.sdwen := '1'; v.rasn := '1'; v.casn := '1';
          v.sdstate := sidle;
          v.idlecnt := (others => '1');
        end if;
      end if;
    when srr1 => -- Load Mode Register "01"
      v.trfc := "0001";                                     -- Extend trfc for mobile ddr
      v.sdcsn := (0 => '0', others => '1'); v.rasn := '0'; v.casn := '0'; 
      v.sdwen := '0'; v.address := (others => '0'); v.ba := "01";
      v.sdstate := srr2;
    when srr2 => -- Read 0
      v.sdcsn := (others => '1'); v.rasn := '1'; v.casn := '1'; v.sdwen := '1';
      if r.trfc = "0000" then                               -- Extend trfc for mobile ddr
        --v.trfc := "011"; -- ****
        if regoutput = 1 then -- delay if registered output
          if r.cfg.cl = '1' then v.trfc := "0101"; else v.trfc := "0100"; end if; -- Extend trfc for mobile ddr
        else
          if r.cfg.cl = '1' then v.trfc := "0100"; else v.trfc := "0011"; end if; -- Extend trfc for mobile ddr
        end if;
        v.sdcsn := (0 => '0', others => '1'); v.casn := '0'; 
        v.sdstate := srr3;
      end if;
    when srr3 => -- SRR done
      v.sdcsn := (others => '1'); v.rasn := '1'; v.casn := '1'; v.sdwen := '1';
      if r.trfc = "0000" then                                   -- Extend trfc for mobile ddr
        v.hready := '1';
        v.startsdold := r.startsd;
        v.sdstate := sidle;
        v.idlecnt := (others => '1');
      end if;
    when others =>
      v.sdstate := sidle;
      v.idlecnt := (others => '1');
    end case;

-- sdram commands

    case r.cmstate is
    when midle =>
      if r.sdstate = sidle then
        case r.cfg.command is
        when CMD_PRE => -- precharge
          v.sdcsn := (others => '0'); v.rasn := '0'; v.sdwen := '0';
          v.address(12) := '1'; v.cmstate := active;
        when CMD_REF => -- auto-refresh
          v.sdcsn := (others => '0'); v.rasn := '0'; v.casn := '0';
          v.cmstate := active;
        when CMD_EMR => -- load-ext-mode-reg
          v.sdcsn := (others => '0'); v.rasn := '0'; v.casn := '0'; 
          v.sdwen := '0'; v.cmstate := active; --v.ba := "01";
          --v.address := "00000000000000";
          if r.cfg.mobileen = "11" then 
            v.ba := "10"; 
            v.address := "000000" & r.cfg.ds(2 downto 0) & r.cfg.tcsr(1 downto 0) 
                         & r.cfg.pasr(2 downto 0);
          else 
            v.ba := "01"; 
          v.address := "00000000000000"; 
          end if;
        when CMD_LMR => -- load-mode-reg
          v.sdcsn := (others => '0'); v.rasn := '0'; v.casn := '0'; 
          v.sdwen := '0'; v.cmstate := active;  v.ba := "00";
          v.address := "00000" & r.cfg.dllrst & "0" & "01" & r.cfg.cl & "0011"; 
        when others => null;
        end case;
      end if;
    when active =>
      v.sdcsn := (others => '1'); v.rasn := '1'; v.casn := '1'; 
      v.sdwen := '1'; --v.cfg.command := "000";
      v.cfg.command := r.sref_tmpcom; v.sref_tmpcom := "000";
      v.cmstate := leadout; v.trfc := (r.cfg.trp and r.cfg.mobileen(1)) & r.cfg.trfc;  -- Extend trfc for mobile ddr
    when others =>
      if r.trfc = "0000" then v.cmstate := midle; end if; -- Extend trfc for mobile ddr

    end case;

-- sdram init

    case r.istate is
    when iidle =>
      if r.cfg.renable = '1' then
        v.cfg.cke := '1'; v.cfg.dllrst := '1';
        if r.cfg.cke = '1' then v.istate := pre; v.cfg.command := CMD_PRE; end if;
      end if;
    when pre =>
      if r.cfg.command = "000" then
        if r.cfg.mobileen = "11" then
          v.cfg.command := CMD_REF; v.istate := ref1;
        else
          v.cfg.command := "11" & r.cfg.dllrst; -- CMD_LMR/CMD_EMR
          if r.cfg.dllrst = '1' then v.istate := emode; else v.istate := lmode; end if;
        end if;
      end if;
    when emode =>
      if r.cfg.command = "000" then
        if r.cfg.mobileen = "11" then
          v.istate := finish; --v.cfg.command := CMD_LMR;
          v.cfg.refon := '1'; v.cfg.renable := '0';
        else
          v.istate := lmode; v.cfg.command := CMD_LMR;
        end if;
      end if;
    when lmode =>
      if r.cfg.command = "000" then
        if r.cfg.mobileen = "11" then
          v.cfg.command := CMD_EMR; v.istate := emode;
        else
          if r.cfg.dllrst = '1' then 
            if r.refresh(9 downto 8) = "00" then -- > 200 clocks delay
              v.cfg.command := CMD_PRE; v.istate := ref1;
            end if;
          else 
            v.istate := finish; --v.cfg.command := CMD_LMR;
            v.cfg.refon := '1'; v.cfg.renable := '0';
          end if;
        end if;
      end if;
    when ref1 =>
      if r.cfg.command = "000" then
        v.cfg.command := CMD_REF; v.cfg.dllrst := '0'; v.istate := ref2; 
      end if;
    when ref2 =>
      if r.cfg.command = "000" then
        --v.cfg.command := CMD_REF; v.istate := pre;
        if r.cfg.mobileen = "11" then v.istate := lmode; v.cfg.command := CMD_LMR;
        else v.cfg.command := CMD_REF; v.istate := pre; end if;
      end if;
    when others =>
      --if r.cfg.renable = '1' then
      if r.cfg.renable = '1' and r.sdstate /= dpd then
        v.istate := iidle; v.cfg.dllrst := '1';
      end if;
    end case;

-- second part of main fsm

    case r.mstate is
    when active =>
      if v.hready = '1' then
        v.mstate := midle;
      end if;
    when others => null;
    end case;

-- sdram refresh counter

    if (((r.cfg.refon = '1') and (r.istate = finish)) or
        (r.cfg.dllrst = '1')) and (r.cfg.pmode /= PM_SR or r.cfg.mobileen(0) = '0')
    then 
      v.refresh := r.refresh - 1;
      if r.cfg.pmode = PM_SR and r.cfg.mobileen(0) = '0' and r.cfg.cke = '0' then 
        v.refresh := (8 => '1', 7 => '1', 6 => '1', 3 => '1', others => '0');
      else
        if (v.refresh(11) and not r.refresh(11))  = '1' then 
          v.refresh := r.cfg.refresh;
          if r.cfg.dllrst = '0' then v.cfg.command := "100"; arefresh := '1'; end if;
        end if;
      end if;
    end if;

-- AHB register access

    if (ra.acc.hio and ra.acc.hwrite and writecfg) = '1' then
      if r.waddr(2 downto 0) = "000" then
        v.cfg.refresh   :=  wdata(11 downto 0); 
        v.cfg.dllrst    :=  wdata(17); 
        v.cfg.command   :=  wdata(20 downto 18); 
        v.cfg.csize     :=  wdata(22 downto 21); 
        v.cfg.bsize     :=  wdata(25 downto 23); 
        v.cfg.trcd      :=  wdata(26); 
        v.cfg.trfc      :=  wdata(29 downto 27); 
        v.cfg.trp       :=  wdata(30); 
        if r.cfg.pmode = "000" then
          v.cfg.cke       :=  wdata(15); 
          v.cfg.renable   :=  wdata(16); 
          v.cfg.refon     :=  wdata(31); 
        end if;
      elsif r.waddr(2 downto 0) = "010" then 
        v.cfg.cl        :=  wdata(30);
        if r.cfg.mobileen(1) = '1' and mobile /= 3 then -- Mobile DDR support
          v.cfg.mobileen(0) :=  wdata(31); 
        end if;
        if r.cfg.mobileen(1) = '1' then
          v.cfg.pasr(5 downto 3)  :=  wdata( 2 downto  0);
          v.cfg.tcsr(3 downto 2)  :=  wdata( 4 downto  3);
          v.cfg.ds(5 downto 3)    :=  wdata( 7 downto  5);
          v.cfg.pmode       :=  wdata(18 downto 16);
          v.cfg.txp         :=  wdata(19);
          v.cfg.txsr        :=  wdata(23 downto 20);
          v.cfg.tcke        :=  wdata(24);
        end if;
      elsif r.waddr(2 downto 0) = "101" and confapi /= 0 then 
        v.cfg.conf(31 downto 0) := wdata(31 downto 0);
      elsif r.waddr(2 downto 0) = "110" and confapi /= 0 then 
        v.cfg.conf(63 downto 32) := wdata(31 downto 0);
      end if;
    end if;
    
    -- Disable CS and DPD when Mobile DDR is Disabled
    if r.cfg.mobileen(0) = '0' then v.cfg.pmode(2) := '0'; end if;

    -- Update EMR when ds, tcsr or pasr change
    if r.cfg.command = "000" and arefresh = '0' and r.cfg.mobileen(0) = '1' then
      if r.cfg.ds(2 downto 0) /= r.cfg.ds(5 downto 3) then
        v.cfg.command := "111"; v.cfg.ds(2 downto 0) := r.cfg.ds(5 downto 3);
      end if;
      if r.cfg.tcsr(1 downto 0) /= r.cfg.tcsr(3 downto 2) then
        v.cfg.command := "111"; v.cfg.tcsr(1 downto 0) := r.cfg.tcsr(3 downto 2);
      end if;
      if r.cfg.pasr(2 downto 0) /= r.cfg.pasr(5 downto 3) then
        v.cfg.command := "111"; v.cfg.pasr(2 downto 0) := r.cfg.pasr(5 downto 3);
      end if;
    end if;

    v.nbdrive := not v.bdrive; 

    if oepol = 1 then bdrive := r.nbdrive; vbdrive := (others => v.nbdrive);
    else bdrive := r.bdrive; vbdrive := (others => v.bdrive);end if; 

-- reset

    if ddr_rst = '0' then
      v.sdstate       := sidle; 
      v.mstate        := midle; 
      v.istate        := finish; 
      v.cmstate       := midle; 
      v.cfg.command   := "000";
      v.cfg.csize     := conv_std_logic_vector(col-9, 2);
      v.cfg.bsize     := conv_std_logic_vector(log2(Mbyte/8), 3);
      if MHz > 100 then v.cfg.trcd :=  '1'; else v.cfg.trcd :=  '0'; end if;
      v.cfg.refon     :=  '0';
      if mobile >= 2 then -- Extend trfc for mobile ddr 
        if MHz > 100 then v.cfg.trfc := conv_std_logic_vector(98*MHz/1000-10, 3);
        else v.cfg.trfc := conv_std_logic_vector(98*MHz/1000-2, 3); end if;
      else v.cfg.trfc := conv_std_logic_vector(75*MHz/1000-2, 3); end if;
      v.cfg.refresh   := conv_std_logic_vector(7800*MHz/1000, 12);
      v.refresh       :=  (others => '0');
      if pwron = 1 then v.cfg.renable :=  '1';
      else v.cfg.renable :=  '0'; end if;
      if MHz > 100 then v.cfg.trp := '1'; else v.cfg.trp := '0'; end if;
      v.dqm           := (others => '1');
      v.sdwen         := '1';
      v.rasn          := '1';
      v.casn          := '1';
      v.hready        := '0';
      v.startsd       := '0';
      v.startsdold    := '0';
      v.cfg.dllrst    := '0';
      if mobile >= 2 then v.cfg.cke := '1';
      else v.cfg.cke  := '0'; end if;
      v.cfg.pasr      := (others => '0');
      v.cfg.tcsr      := (others => '0');
      v.cfg.ds        := (others => '0');
      v.cfg.pmode     := (others => '0');
      v.cfg.txsr      := conv_std_logic_vector(120*MHz/1000, 4);
      v.cfg.txp       := '1';
      v.idlecnt := (others => '1');
      v.ck := (others => '1');
      if mobile >= 2 then v.cfg.mobileen := "11";    -- Default: Mobile DDR
      elsif mobile = 1 then v.cfg.mobileen := "10"; -- Mobile DDR support enable
      else v.cfg.mobileen := "00"; end if;          -- Mobile DDR support disable
      v.sref_tmpcom   := "000";
      v.cfg.cl        := '0'; -- CL = 3/2 -- ****
      v.cfg.tcke      := '1';
      if confapi /= 0 then
        v.cfg.conf(31 downto  0) := conv_std_logic_vector(conf0, 32); --x"0000A0A0";
        v.cfg.conf(63 downto 32) := conv_std_logic_vector(conf1, 32);--x"00060606";
      end if;
    end if;
    
    if regoutput = 1 then
      if oepol = 1 then v.sdo_bdrive := r.nbdrive;            -- *** ??? delay ctrl
      else v.sdo_bdrive := r.bdrive; end if;
      v.sdo_qdrive := not (v.qdrive or r.nbdrive);                          
    end if;

    ri <= v; 
    ribdrive <= vbdrive; 
    rwdata <= readdata;

  end process;

  ahbso.hconfig <= hconfig;
  ahbso.hirq    <= (others => '0');
  ahbso.hsplit  <= (others => '0');
  ahbso.hindex  <= hindex;

  ahbregs : process(clk_ahb) begin 
    if rising_edge(clk_ahb) then
      ra <= rai; 
    end if;
  end process;

  ddrregs : process(clk_ddr, rst, ddr_rst) begin 
    if rising_edge(clk_ddr) then
      r <= ri; rbdrive <= ribdrive;
      ddr_rst_gen <= ddr_rst_gen(2 downto 0) & '1'; 
    end if;
    if rst = '0' then
      ddr_rst_gen <= "0000";
    end if;
    if (ddr_rst = '0') then
      r.sdcsn  <= (others => '1'); r.bdrive <= '1'; r.nbdrive <= '0';
      if oepol = 0 then rbdrive <= (others => '1');
      else rbdrive <= (others => '0'); end if;
      --r.cfg.cke <= '0';
      if mobile = 2 then r.cfg.cke <= '1';
      else r.cfg.cke  <= '0'; end if;
    end if;
  end process;

  ddr_read_regs : process(clkread) begin 
    if rising_edge(clkread) then
      rwrite <= ri.hready; waddr2 <= r.waddr;
    end if;
  end process;

  sdo.address  <= '0' & r.address when regoutput = 1 else '0' & ri.address;                     -- *** ??? delay ctrl
  sdo.ba       <= '0' & r.ba when regoutput = 1 else '0' & ri.ba;                                     -- *** ??? delay ctrl
  sdo.bdrive   <= r.sdo_bdrive when regoutput = 1 else r.nbdrive when oepol = 1 else r.bdrive;  -- *** ??? delay ctrl
  sdo.qdrive   <= r.sdo_qdrive when regoutput = 1 else not (ri.qdrive or r.nbdrive);            -- *** ??? delay ctrl
  sdo.vbdrive(31 downto 0)  <= rbdrive;
  sdo.vbdrive(63 downto 32) <= (others => '0');
  sdo.sdcsn    <= r.sdcsn when regoutput = 1 else ri.sdcsn;                                     -- *** ??? delay ctrl
  sdo.sdwen    <= r.sdwen when regoutput = 1 else ri.sdwen;                                     -- *** ??? delay ctrl
  sdo.dqm      <= "111111111111" & r.dqm_dly when regoutput = 1 else "111111111111" & r.dqm;    -- *** ??? delay ctrl
  sdo.rasn     <= r.rasn when regoutput = 1 else ri.rasn;                                       -- *** ??? delay ctrl
  sdo.casn     <= r.casn when regoutput = 1 else ri.casn;                                       -- *** ??? delay ctrl
  sdo.data     <= zero32 & zero32 & zero32 & r.wdata when regoutput = 1 else zero32 & zero32 & zero32 & wdata; -- *** ??? delay ctrl
  sdo.sdck     <= r.ck_dly when regoutput = 1 else r.ck; -- *** ??? delay ctrl
  sdo.sdcke    <= (others => r.cke_dly) when regoutput = 1 else (others => r.cfg.cke); -- *** ??? delay ctrl
  sdo.moben    <= r.cfg.mobileen(0);
  sdo.conf     <= r.cfg.conf;
  sdo.ce       <= '0';
  sdo.cal_rst  <= '0';
  sdo.oct      <= '0';
  sdo.xsdcsn   <= (others => '0');
  sdo.cb       <= (others => '0');
  sdo.cal_en   <= (others => '0');
  sdo.cal_inc  <= (others => '0');
  sdo.odt      <= (others => '0');
  sdo.vcbdrive <= (others => '0');
  sdo.cbdqm    <= (others => '0');
  sdo.cbcal_en <= (others => '0');
  sdo.cbcal_inc<= (others => '0');
  sdo.read_pend<= (others => '0');
  sdo.regwdata <= (others => '0');
  sdo.regwrite <= (others => '0');
  sdo.cal_pll  <= (others => '0');

  -- AMBA data mux:ing
  hwdata       <= ahbreadword(ahbsi.hwdata, ra.haddr(4 downto 2));
 
  read_buff : syncram_2p 
  generic map (tech => memtech, abits => 6, dbits => 32, sepclk => 1, wrfst => 0)
  port map ( rclk => clk_ahb, renable => vcc, raddress => rai.raddr,
    dataout => rdata, wclk => clk_ddr, write => ri.hready,
--    dataout => rdata, wclk => clkread, write => rwrite,
    waddress => r.waddr, datain => rwdata);
--    waddress => waddr2, datain => rwdata);

  write_buff : syncram_2p 
  generic map (tech => memtech, abits => 6, dbits => 32, sepclk => 1, wrfst => 0)
  port map ( rclk => clk_ddr, renable => vcc, raddress => r.waddr,
    dataout => wdata, wclk => clk_ahb, write => ra.write,
    waddress => ra.haddr(7 downto 2), datain => hwdata);

-- pragma translate_off
  bootmsg : report_version 
  generic map (
    msg1 => "ddrsp" & tost(hindex) & ": 16-bit DDR266 controller rev " & 
      tost(REVISION) & ", " & tost(Mbyte) & " Mbyte, " & tost(MHz) &
      " MHz DDR clock");
-- pragma translate_on

end;

