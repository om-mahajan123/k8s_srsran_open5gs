#!/usr/bin/env python3
# -*- coding: utf-8 -*-

#
# SPDX-License-Identifier: GPL-3.0
#
# GNU Radio Python Flow Graph
# Title: srsRAN_multi_UE
# GNU Radio version: 3.10.1.1

from gnuradio import blocks
from gnuradio import gr
import sys
import signal
from argparse import ArgumentParser
from gnuradio import zeromq


class multi_ue_scenario(gr.top_block):
    def __init__(self, num_ues):
        gr.top_block.__init__(self, "srsRAN_multi_UE")

        ##################################################
        # Variables
        ##################################################
        zmq_timeout = 100
        zmq_hwm = -1
        samp_rate = 23040000
        slow_down_ratio = 1

        ##################################################
        # Base Blocks (Always included)
        ##################################################
        self.zeromq_req_source_0 = zeromq.req_source(gr.sizeof_gr_complex, 1, 'tcp://10.10.3.231:2000', zmq_timeout, False, zmq_hwm)
        self.zeromq_rep_sink_0_1 = zeromq.rep_sink(gr.sizeof_gr_complex, 1, 'tcp://10.10.3.232:2001', zmq_timeout, False, zmq_hwm)

        ##################################################
        # UE-specific Blocks
        ##################################################
        self.zeromq_req_sources = []
        self.zeromq_rep_sinks = []
        self.blocks_throttle = blocks.throttle(gr.sizeof_gr_complex*1, samp_rate / slow_down_ratio, True)
        self.blocks_add_xx = blocks.add_vcc(1)

        # Create zeromq blocks dynamically for each UE
        for i in range(num_ues):
            req_port = 2101 + i
            rep_port = 2201 + i
            req_source = zeromq.req_source(gr.sizeof_gr_complex, 1, f'tcp://10.10.3.232:{req_port}', zmq_timeout, False, zmq_hwm)
            rep_sink = zeromq.rep_sink(gr.sizeof_gr_complex, 1, f'tcp://10.10.3.232:{rep_port}', zmq_timeout, False, zmq_hwm)
            self.zeromq_req_sources.append(req_source)
            self.zeromq_rep_sinks.append(rep_sink)
            # Connect req source to add block
            self.connect((req_source, 0), (self.blocks_add_xx, i))
            # Connect throttle to rep sink
            self.connect((self.blocks_throttle, 0), (rep_sink, 0))

        # Connections for base blocks
        self.connect((self.blocks_add_xx, 0), (self.zeromq_rep_sink_0_1, 0))
        self.connect((self.zeromq_req_source_0, 0), (self.blocks_throttle, 0))

def main():
    parser = ArgumentParser(description='srsRAN_multi_UE setup')
    parser.add_argument('-n', '--num-ues', type=int, required=True, help='Number of UEs')
    args = parser.parse_args()

    tb = multi_ue_scenario(args.num_ues)

    def sig_handler(sig=None, frame=None):
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    tb.start()

    try:
        input('Press Enter to quit: ')
    except EOFError:
        pass
    tb.stop()
    tb.wait()


if __name__ == '__main__':
    main()
