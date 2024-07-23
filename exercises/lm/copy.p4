/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>


const bit<16> TYPE_IPV6 = 0x86DD;
const bit<8>  TYPE_BITS = 0xFF;
const bit<5>  TYPE_TO64 = 0x01;
const bit<5>  TYPE_TO128 = 0x02;
const bit<5>  TYPE_TO256 = 0x03;
const bit<5>  TYPE_TO512 = 0x04;
const bit<5>  TYPE_TO1024 = 0x05;
const bit<5>  TYPE_TO1280 = 0x06;
const bit<5>  TYPE_TO1518 = 0x07;

const bit<32> MIN_VALUE = 0x0;
const bit<32> MAX_VALUE = 10000;

typedef bit<48> time_t;
typedef bit<48> macAddr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv6_t {
    bit<4>    version;
    bit<8>    trafClass;
    bit<20>   flowLabel;
    bit<16>   payloadLen;
    bit<8>    nextHeader;
    bit<8>    hopLimit;
    bit<128>  srcAddr;
    bit<128>  dstAddr;
}

struct metadata {
    bit<1>    generate;
    bit<9>    out_port;
    bit<10>   time;
    bit<16>   delay_select;
}

struct headers {
    ethernet_t   ethernet;
    ipv6_t       ipv6;
}

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV6: parse_ipv6;
            default: accept;
        }
    }

    state parse_ipv6{
        packet.extract(hdr.ipv6);
        transition accept;
    }

}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    /*
    register <bit<32>>(MAX_RECORD) records;
    register <bit<32>>(MAX_RECORD) map;
    register <bit<32>>(MAX_RECORD) typomap;
    register <bit<32>> (1) index_register;
    register <bit<32>> (1) max_recv_register;
    register <bit<32>> (1) loss1_register;
    register <bit<32>> (1) loss2_register;
    register <bit<32>> (1) loss_count;

    action drop() {
        mark_to_drop(standard_metadata);
        meta.drop = 1;
    }

    action idp_forward(macAddr_t dstAddr, ip6Addr_t ip, egressSpec_t port, ip6Addr_t cur_ip) {
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        standard_metadata.egress_spec = port;
        hdr.ipv6.dstAddr = ip;
        hdr.ipv6.hopLimit = hdr.ipv6.hopLimit - 1;
        if(meta.typo == 1){
            hdr.idp.srvType = 1;
        }
        if(meta.typo == 2){
            hdr.idp.srvType = 2;
        }
        hdr.seadp.rs_ip = cur_ip;
    }

    table idp_exact {
        key = {
            meta.typo: exact;
        }
        actions = {
            idp_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }
    */
    action ipv6_forward(bit<9> port) {
        standard_metadata.egress_spec = port;
        if(port == 1 && meta.time == 1){
            standard_metadata.egress_spec = 4;
        }
        if(port == 1 && meta.time == 2){
            standard_metadata.egress_spec = 5;
        }
        meta.out_port = port;
    }

    table ipv6_exact {
        key = {
            hdr.ipv6.dstAddr: exact;
        }
        actions = {
            ipv6_forward;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    action generate(bit<1> flag) {
        meta.generate = flag;
    }

    table generate_exact {
        key = {
            hdr.ipv6.version: exact;
        }
        actions = {
            generate;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    apply {
        generate_exact.apply();
        meta.time = 0;
        time_t cur = standard_metadata.ingress_global_timestamp;
        hash(meta.delay_select, HashAlgorithm.crc32, MIN_VALUE, {cur}, MAX_VALUE);
        
        if(meta.generate == 1 && meta.delay_select < 3333){
            meta.time = 1;
        }
        if(meta.generate == 1 && meta.delay_select > 6666){
            meta.time = 2;
        }

        ipv6_exact.apply();
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    register <bit<1>> (2) generate_register;
    register <bit<1>> (2) init_register;
    register <bit<1>> (2) flag_ds_register; // 延迟样本标志位
    register <time_t> (2) t_ds_register;  // 上次发送延迟样本的时间
    register <time_t> (2) roundtrip_delay_register;  // 往返时延最新测量值
    // 用于块生成：
    register <bit<1>> (2) cur_block_r;
    register <bit<1>> (2) block_length_calculated_r;
    register <bit<48>>(2) block_generation_count_r;
    register <time_t> (2) block_bound_time_r;
    register <bit<48>>(2) block_length_r;
    // 用于块解析：
    register <bit<48>>(2) count0_r;
    register <bit<48>>(2) count1_r;
    register <time_t>(2) time0_r;
    register <time_t>(2) time1_r;
    register <bit<48>>(2) receive_length_r;
    //用于通告
    // register <bit<48>>(2) receive_length_r;
    register <bit<48>>(2) initial_length_r;
    // register <bit<48>>(2) block_generation_count_r;
    register <bit<48>>(2) cur_notification0_r;

    action drop() {
        mark_to_drop(standard_metadata);
    }

    table drop_table {
        key = {
            hdr.ipv6.version: exact;
        }
        actions = {
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    apply { 
        if(hdr.ipv6.dstAddr == 21267647932558653966460912964485644289 || hdr.ipv6.dstAddr == 21267647932558653966460912964485644290 || hdr.ipv6.dstAddr == 21267647932558653966460912964485644291 || hdr.ipv6.dstAddr == 21267647932558653966460912964485644292){
            // 块生成
            if(meta.out_port == 1){
                bit<1> block_calculated;
                block_length_calculated_r.read(block_calculated, 1);
                if(block_calculated == 1){
                    bit<1> cur_block;
                    cur_block_r.read(cur_block, 1);
                    hdr.bits.loss = cur_block;
                    bit<48> block_generation_count;
                    block_generation_count_r.read(block_generation_count, 1);
                    block_generation_count = block_generation_count + 1;
                    block_generation_count_r.write(1, block_generation_count);

                    bit<48> block_length;
                    block_length_r.read(block_length, 1);
                    if(block_generation_count == block_length){
                        cur_block = 1 - cur_block;
                        cur_block_r.write(1, cur_block);
                        block_length_calculated_r.write(1, 0);
                        block_generation_count_r.write(1, 0);

                        time_t cur_time = standard_metadata.egress_global_timestamp;
                        block_bound_time_r.write(1, cur_time);
                    }
                }
                else{
                    bit<1> init;
                    init_register.read(init, 1);
                    if (init == 0){
                        init_register.write(1, 1);
                        time_t cur_time = standard_metadata.egress_global_timestamp;
                        block_bound_time_r.write(1, cur_time);
                    }
                    bit<1> cur_block;
                    cur_block_r.read(cur_block, 1);
                    hdr.bits.loss = cur_block;
                    bit<48> block_generation_count;
                    block_generation_count_r.read(block_generation_count, 1);
                    block_generation_count = block_generation_count + 1;
                    block_generation_count_r.write(1, block_generation_count);

                    time_t cur_time = standard_metadata.egress_global_timestamp;
                    time_t block_bound_time;
                    block_bound_time_r.read(block_bound_time, 1);
                    block_bound_time = block_bound_time + 7000000;
                    if(block_bound_time < cur_time){
                        bit<48> len = 1;
                        bit<1> calculated = 0;
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }
                        if(calculated == 0 && len < block_generation_count){
                            len = len + len; if(len > block_generation_count) {calculated = 1; } }

                        block_length_r.write(1, len);
                        block_length_calculated_r.write(1, 1);
                    }
                    block_generation_count_r.read(block_generation_count, 1);
                    bit<48> block_length;
                    block_length_r.read(block_length, 1);
                    if(block_generation_count == block_length){
                        cur_block = 1 - cur_block;
                        cur_block_r.write(1, cur_block);
                        block_length_calculated_r.write(1, 0);
                        block_generation_count_r.write(1, 0);
                        cur_time = standard_metadata.egress_global_timestamp;
                        block_bound_time_r.write(1, cur_time);
                    }
                }
            }
            // 接收块
            if(standard_metadata.ingress_port == 1 || standard_metadata.ingress_port == 4 || standard_metadata.ingress_port == 5){
                if(hdr.bits.loss == 0){
                    bit<48> count0;
                    count0_r.read(count0, 1);
                    count0 = count0 + 1;
                    count0_r.write(1, count0);
                    time_t cur_time = standard_metadata.egress_global_timestamp;
                    time0_r.write(1, cur_time);
                }
                else{
                    bit<48> count1;
                    count1_r.read(count1, 1);
                    count1 = count1 + 1;
                    count1_r.write(1, count1);
                    time_t cur_time = standard_metadata.egress_global_timestamp;
                    time1_r.write(1, cur_time);
                }
                time_t time0;
                time0_r.read(time0, 1);
                bit<48> count0;
                count0_r.read(count0, 1);
                time_t time1;
                time1_r.read(time1, 1);
                bit<48> count1;
                count1_r.read(count1, 1);
                time_t cur_time = standard_metadata.egress_global_timestamp;
                cur_time = cur_time - 3000000;
                if(time0 != 0 && cur_time > time0){
                    time0_r.write(1, 0);
                    count0_r.write(1, 0);
                    bit<48> receive_length;
                    receive_length_r.write(1, count0);
                    
                    bit<48> initial_length = 1;
                    bit<1> calculated = 0;
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count0){
                        initial_length = initial_length + initial_length; if(initial_length > count0) {calculated = 1; } }

                    initial_length_r.write(1, initial_length);
                }
                if(time1 != 0 && cur_time > time1){
                    time1_r.write(1, 0);
                    count1_r.write(1, 0);
                    bit<48> receive_length;
                    receive_length_r.write(1, count1);

                    bit<48> initial_length = 1;
                    bit<1> calculated = 0;
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }
                    if(calculated == 0 && initial_length < count1){
                        initial_length = initial_length + initial_length; if(initial_length > count1) {calculated = 1; } }

                    initial_length_r.write(1, initial_length);
                }
            }
            
            if(meta.out_port == 1 && hdr.bits.delay != 1){
                bit<16> loss_select;
                time_t cur = standard_metadata.ingress_global_timestamp;
                hash(loss_select, HashAlgorithm.crc32, MIN_VALUE, {cur}, MAX_VALUE);
                if(loss_select < 1000){
                    drop_table.apply();
                }
            }
            
            
            // 块生成


        }
    }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply { }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv6);
        packet.emit(hdr.bits);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
