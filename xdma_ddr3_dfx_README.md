# xdma_ddr3_dfx

I'll try to summarize everything going on in this project here.

## Top-level Block Design
![image info](.images/xdma_ddr3_dfx.png)

At a high level, the top-level is responsible for instantiating the following:
- **XDMA IP core**: this makes the whole design accessible via PCIe
- **MIG 7-series IP core**: this allows access to DDR3 via PCIe and Reconfigurable Partition
- **AXI HWICAP IP core**: this provides partrial bitstream reconfiguration via PCIe using driver in `app/hwicap_write_bitstream` 
- **DFX Socket (hier block)**: this grouping of IPs ensures the Reconfigurable Partition can be safely reprogrammed
- **DFX Partition (block design container)**: this block design is where all the fun stuff will happen

The other IPs are more or less for support:
- **SmartConnects**: these just route M_AXI_LITE, M_AXI and S_AXI interfaces
- **Clocking Wizard**: provides the MIG7 IP with a 200 MHz
- **AXI GPIO**: provides write access to LEDs and read access to MIG7 status

## dfx_socket (Hierarchical Block)
![image info](.images/dfx_socket.png)

This portion of the design is responsible for 3 things:
- Shutting down RP's master AXI bus
- Shutting down RP's slave AXI bus
- Decoupling RP's resetn line

There are a few things that act as support, but are also important:
- **AXI Register Slices**: these "lock" the interfaces down so they are kept consistent. Very important.
- **AXI GPIO**: this provides individual control of shutdown and decouple lines and read access to IPs status lines

The idea is you'd follow this sequence when reprogramming an RP:
- Disengage the RP by shutting down the AXI buses and decoupling the reset
- Write a partial bitstream to HWICAP
- Re-engage the RP by clearing the shutdown and decouple registers

## dfx_partition (Block Design Container)
![image info](.images/dfx_partition.png)

This should practically be a playground to do whatever you want. As long as you don't modify the interfaces going in and out of this block design container.

Important things to mention:
- **Address Range**: the SmartConnect in the static region needs to be informed of the range the RP will need
    - Don't randomly address AXI mapped IPs
    - Make sure address selected in RP are within the aperture configured in Static Region
    - I've allocated the range 0x4001_0000 - 0x4001_FFFF (64 KB) in the default build so when an RP is built any address in that range can be used
- **AXI Register Slices**: these serve the same purpose as those in `dfx_socket` and shall **always** match settings
    - Don't remove these or change their settings.

### Current State

Includes the following:
- MM2S DataMover and control module
- S2MM DataMover and control module
- AXI Stream FIFO

With those a demo of the following is possible:
- Write a buffer to DDR3 via PCIe
- MM2S DataMover will read from DDR3 buffer
- AXI Stream FIFO forwards data
- S2MM DataMover will write to DDR3 buffer
- Read a buffer from DDR33 via PCIe

This accomplishes a simple loopback test. This is done in `app/scripts/dma/test-datamover.sh`.

Loads of hardware accelerated activities can be performed just by swapping out the FIFO.

---

# xdma_ddr3_dfx (русская версия)

Ниже — русский перевод описания проекта.

## Верхнеуровневый Block Design

На верхнем уровне дизайн инстанцирует:
- **IP-ядро XDMA** — обеспечивает доступ ко всему дизайну через PCIe;
- **IP-ядро MIG 7-series** — доступ к DDR3 через PCIe и Reconfigurable Partition;
- **IP-ядро AXI HWICAP** — частичная реконфигурация битстрима через PCIe (драйвер в `app/hwicap_write_bitstream`);
- **DFX Socket (иерархический блок)** — группа IP, обеспечивающая безопасную перепрошивку RP;
- **DFX Partition (block design container)** — сюда и помещается вся прикладная логика.

Вспомогательные IP:
- **SmartConnects** — маршрутизация интерфейсов M_AXI_LITE, M_AXI, S_AXI;
- **Clocking Wizard** — 200 МГц для MIG7;
- **AXI GPIO** — запись в LED и чтение статуса MIG7.

## dfx_socket (иерархический блок)

Решает 3 задачи:
- выключение master AXI-шины RP;
- выключение slave AXI-шины RP;
- развязка линии resetn RP.

Вспомогательное, но важное:
- **AXI Register Slices** — "фиксируют" интерфейсы, удерживая их согласованными;
- **AXI GPIO** — индивидуальное управление линиями shutdown/decouple и чтение статуса IP.

Порядок перепрошивки RP:
- вывести RP из работы (выключить AXI-шины + развязать reset);
- записать частичный битстрим в HWICAP;
- вернуть RP в работу (снять shutdown/decouple).

## dfx_partition (Block Design Container)

По сути "песочница" — можно делать что угодно, не меняя интерфейсы на входе/выходе этого BDC.

Важно:
- **Диапазон адресов**: SmartConnect в static-регионе должен знать диапазон, нужный RP.
  - не адресовать AXI-IP хаотично;
  - адреса RP должны попадать в апертуру, настроенную в Static Region;
  - в default-сборке выделен диапазон 0x4001_0000 - 0x4001_FFFF (64 КБ).
- **AXI Register Slices**: назначение то же, что в `dfx_socket`, настройки **всегда** должны совпадать;
  не удалять и не менять их настройки.

### Текущее состояние

Включает:
- MM2S DataMover с модулем управления;
- S2MM DataMover с модулем управления;
- AXI Stream FIFO.

Возможна демонстрация:
- запись буфера в DDR3 через PCIe;
- MM2S DataMover читает буфер из DDR3;
- AXI Stream FIFO пересылает данные;
- S2MM DataMover пишет в буфер DDR3;
- чтение буфера из DDR3 через PCIe.

Это простой loopback-тест (`app/scripts/dma/test-datamover.sh`).
Множество аппаратно-ускоренных задач можно реализовать, просто заменив FIFO.
