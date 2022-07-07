package nkn

import (
	"github.com/btcsuite/btcd/chaincfg/chainhash"
	"github.com/ethereum/go-ethereum/common"
	dnsresolver "github.com/nknorg/dns-resolver-go"
	ethresolver "github.com/nknorg/eth-resolver-go"
	"github.com/nknorg/ncp-go"
	"github.com/nknorg/nkn-sdk-go"
	"github.com/nknorg/nkn/v2/config"
	"github.com/nknorg/nkngomobile"
	"github.com/nknorg/reedsolomon"
	"golang.org/x/mobile/bind"
)

var (
	_ = ncp.DefaultConfig
	_ = nkn.NewStringArray
	_ = config.ConfigFile
	_ = dnsresolver.NewResolver
	_ = nkngomobile.NewStringArray
	_ = reedsolomon.New
	_ = bind.GenGo
	_ = ethresolver.NewResolver
	_ = chainhash.NewHash
	_ = common.NewMixedcaseAddress
)
