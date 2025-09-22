
# 定义函数
fch_cli_cmd() {
    ./src/freecash-cli -regtest -datadir=/Users/caisirius/freecash_regtest "$@"
}

# 将整数转换为小端字节序的十六进制（最小字节表示）
int_to_little_endian_hex() {
    local num=$1
    # 处理0的特殊情况
    if [ "$num" -eq 0 ]; then
        echo "00"
        return
    fi
    
    # 转换为十六进制并确保偶数长度
    local hex
    hex=$(printf '%x' "$num")
    if [ $(( ${#hex} % 2 )) -ne 0 ]; then
        hex="0$hex"
    fi
    
    # 检查最高位字节是否>=0x80（即最高位为1）
    local first_byte=${hex:0:2}
    local need_padding=0
    if [ $((0x$first_byte)) -ge 128 ]; then
        need_padding=1
    fi
    
    # 反转字节顺序（小端序）
    local little_endian=""
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        little_endian="${little_endian}${hex:$i:2}"
    done
    
    # 如果需要填充，在小端序末尾添加00字节
    if [ $need_padding -eq 1 ]; then
        little_endian="${little_endian}00"
    fi
    
    echo "$little_endian"
}


block_height=$(fch_cli_cmd getblockcount)
echo "current block height is $block_height"

if (( block_height < 100 )); then
    echo -e "+++ now we generate 101 blocks \n"
    gen_101=$(fch_cli_cmd generate 101)
fi

# 生成一个地址
echo "Now get a new address, send to this addr"
address=$(fch_cli_cmd getnewaddress "keypair")
privkey=$(fch_cli_cmd dumpprivkey $address)
pubkey=$(fch_cli_cmd getaddressinfo $address | grep -o '"pubkey": "[^"]*' | sed 's/"pubkey": "//')
echo "Public Key: $pubkey"

# 获取当前区块高度
block_height=$(fch_cli_cmd getblockcount)
echo "current block height is $block_height"

# 设置 CLTV 锁定的区块高度。我们选择当前高度 + 10 个区块。
cltv_locktime=$((block_height + 10))
echo "CLTV Locktime (block height): $cltv_locktime"

# 获取锁定区块高度 的 小端 1 字节
# <最小编码限制> 见 CScriptNum::IsMinimallyEncoded
# 现在的 cltv_locktime 是111 按<最小编码限制>限制，只能1个字节
# LOCK_HEX=$(printf "%02x" $cltv_locktime | tac -rs ..)
LOCK_HEX=$(int_to_little_endian_hex $cltv_locktime)

# 计算LOCK_HEX有多少个字节
LEN_OFLOCK_HEX=$(printf "%02x" $((${#LOCK_HEX} / 2 )))

# 拼装 redeem_script 
# 解释 redeem_script ：
# 01${LOCK_HEX} → 1个字节的 LOCK_HEIGHT，小端字节序
# b1            → CLTV (0xb1 = OP_CHECKLOCKTIMEVERIFY)
# 75            → OP_DROP
# 21${pubkey}   → 33个字节 的 pubkey
# ac            → OP_CHECKSIG
redeem_script="${LEN_OFLOCK_HEX}${LOCK_HEX}b17521${pubkey}ac"
echo "redeem_script is: $redeem_script"

# 获取 p2sh 地址
p2sh=$(fch_cli_cmd decodescript $redeem_script | grep -o '"p2sh": "[^"]*' | sed 's/"p2sh": "//')
echo "the p2sh addr is : $p2sh"

# 导入钱包
fch_cli_cmd importaddress $redeem_script "cltv_script" false true

echo ">>> getaddressinfo $p2sh"
fch_cli_cmd getaddressinfo $p2sh

scriptPubKey=$(fch_cli_cmd getaddressinfo $p2sh | grep -o '"scriptPubKey": "[^"]*' | sed 's/"scriptPubKey": "//')
echo "scriptPubKey is : $scriptPubKey"

# 用 sendtoaddress 简单，但是要判断 p2sh 在哪个输出
txid=$(fch_cli_cmd sendtoaddress $p2sh 24.96)

echo "generate a new tx :"
tx_details=$(fch_cli_cmd getrawtransaction $txid 1)
echo $tx_details

# 判断 p2sh 在哪个vout
p2sh_vout=$(echo "$tx_details" | jq -r '.vout[] | select(.scriptPubKey.type == "scripthash") | .n')
echo " ** the p2sh_vout is $p2sh_vout"

echo "generate new blocks "
fch_cli_cmd generate 1

echo -e "\n\n\n **** now we spend the p2sh vout "
# 构造花费该 P2SH 输出的交易
# 获取这个 P2SH 输出的 UTXO
p2sh_utxo_txid="$txid"

# 创建一个新地址来接受fch
recipient_address=$(fch_cli_cmd getnewaddress "cltv-destination")
echo " **** a new address to recive: $recipient_address"

# 创建交易
raw_spend_tx=$(fch_cli_cmd createrawtransaction '[{"txid":"'"$p2sh_utxo_txid"'", "vout":'"$p2sh_vout"', "sequence":4278190079}]' '{"'"$recipient_address"'": 24.92}' $cltv_locktime)
echo "raw_spend_tx is: $raw_spend_tx"

echo "--------------param start-----------------"
echo privkey=$privkey
echo raw_spend_tx=$raw_spend_tx
echo p2sh_utxo_txid=$p2sh_utxo_txid
echo p2sh_vout=$p2sh_vout
echo scriptPubKey=$scriptPubKey
echo redeem_script=$redeem_script
echo amount=24.96
echo "--------------param end-----------------"
echo "--把以上内容粘贴到可以签名CLTV的钱包的terminal中--"


echo "\n尝试用钱包来签名，将失败，因为CLTV不是标准交易，钱包不支持"

# 注意以上的参数：
# 1. 设置了 nLocktime 为 $cltv_locktime
# 2. 设置了 sequence 为 4278190079 即 0xfffffffe

# 签名交易
# 我们需要提供赎回脚本，因为它是 P2SH
sign_return=$(fch_cli_cmd signrawtransactionwithwallet $raw_spend_tx '[{"txid": "'"$p2sh_utxo_txid"'", "vout": '"$p2sh_vout"', "scriptPubKey": "'"$scriptPubKey"'", "redeemScript": "'"$redeem_script"'", "amount": 24.96}]')


echo "sign_return is : \n$sign_return"

signed_tx=$(echo "$sign_return" | jq -r '.hex')


echo '\n 我们应该在新编译的钱包里去签名，再回来到这个fch的钱包的机器上，用刚刚签名的 hex 来打包发送'

# 检查complete是否为true
if echo "$sign_return" | jq -e '.complete == true' >/dev/null; then
  echo "Transaction is complete"
else
  echo "Transaction is incomplete"
  return -1
fi

echo "try to inot mempool, will reject:"
ret=$(fch_cli_cmd testmempoolaccept '["'"$signed_tx"'"]')

echo $ret

if echo "$ret" | jq -e '.[0].allowed != false' >/dev/null; then
  echo "Unexpected ret"
  return -1
fi

