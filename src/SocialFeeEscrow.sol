// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/utils/cryptography/EIP712.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./flap/IVaultSchemasV1.sol";
import {IXGeneralVerifier} from "./flap/IXGeneralVerifier.sol";

/// @notice Fuente viva del attester vigente (la factory). Rotable via rotateAttester.
interface IAttesterSource {
    function attester() external view returns (address);
}

/// @title SocialFeeEscrow (FLEDGE)
/// @notice Acumula el tax (ETH nativo) de un token de Flap para UNA identidad
///         (wallet / github / twitter) y solo lo entrega a la wallet que la probó.
///         Inmutable. Sin owner, sin pause, sin upgrade. Sin admin keys nuestras: las UNICAS
///         funciones gateadas (emergencyWithdrawNative, setRescueForward) las controla el
///         Guardian OFICIAL de Flap (publico, per-chain, heredado de VaultBase) — nunca una
///         key de FLEDGE/del creator. Ver AUDIT-NOTES.md v3 (Audit v3, finding 4).
contract SocialFeeEscrow is VaultBaseV2, EIP712 {
    uint8 public constant TYPE_WALLET = 0;
    uint8 public constant TYPE_GITHUB = 1;
    uint8 public constant TYPE_TWITTER = 2;

    bytes32 public constant BIND_TYPEHASH =
        keccak256("Bind(address payoutWallet,uint256 nonce,uint256 deadline)");

    address public immutable taxToken; // direccion PREDICHA del token; puede no tener codigo aun
    address public immutable creator;
    uint8 public immutable identityType;
    /// @notice Fuente VIVA del attester (la factory) — ruta GITHUB. Preaudit Flap (High):
    ///         antes el attester era immutable por vault (key comprometida = vouchers forjables
    ///         para siempre, sin rotacion); ahora el vault lee el vigente de la factory.
    address public immutable attesterSource;
    address public immutable xVerifier; // XGeneralVerifier oficial de Flap, ruta TWITTER
    /// @notice La wallet-identidad original (solo TYPE_WALLET; 0x0 para github/twitter).
    ///         NO muta con rebinds: es quien puede rotar la wallet de cobro.
    address public immutable identityWallet;
    uint64 public immutable recoveryAfter; // 0 = nunca
    string public identityValue; // normalizada por la factory; vacia para TYPE_WALLET

    address public boundWallet; // 0x0 hasta probar identidad; TYPE_WALLET la fija el constructor
    uint256 public bindNonce;
    uint256 public totalPaid;
    /// @notice Replay guard GLOBAL de la ruta X (Snowflake crece). Audit v3 (Low, finding 6):
    ///         antes era `mapping(address => uint128)` (por-claimer) — una wallet vieja nombrada
    ///         en un tweet desactualizado pero aun oracle-valido podia rebindear y desviar fondos
    ///         despues de que el handle real ya hubiera probado una wallet mas nueva. Ahora, igual
    ///         que el bindNonce de github, CUALQUIER claim exitoso invalida los tweetIds menores
    ///         para TODOS los candidatos, no solo para si misma.
    uint128 public lastTweetId;
    /// @notice Guardian-only kill-switch: si esta prendido, receive() reenvia el ETH entrante a
    ///         `rescueTo` en vez de acumularlo. Audit v3 (High, finding 4, SYS-REQ-RESCUE-MECHANISM).
    bool public rescueForward;
    address public rescueTo;

    event Bound(address indexed payoutWallet, uint256 nonce);
    event Swept(address indexed to, uint256 amount);
    event Recovered(address indexed to, uint256 amount);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event RescueForwardSet(bool on, address to);
    event Forwarded(address indexed to, uint256 amount);

    constructor(
        address taxToken_,
        address creator_,
        uint8 identityType_,
        string memory identityValue_,
        address identityWallet_,
        address attesterSource_,
        address xVerifier_,
        uint64 recoveryAfter_
    ) EIP712("SocialFeeEscrow", "1") {
        require(identityType_ <= TYPE_TWITTER, unicode"bad identity type / 身份类型无效");
        taxToken = taxToken_;
        creator = creator_;
        identityType = identityType_;
        identityValue = identityValue_;
        attesterSource = attesterSource_;
        xVerifier = xVerifier_;
        recoveryAfter = recoveryAfter_;
        identityWallet = identityType_ == TYPE_WALLET ? identityWallet_ : address(0);
        if (identityType_ == TYPE_WALLET) {
            require(identityWallet_ != address(0), unicode"wallet required / 需要钱包地址");
            boundWallet = identityWallet_;
            emit Bound(identityWallet_, 0);
        } else if (identityType_ == TYPE_GITHUB) {
            require(attesterSource_ != address(0), unicode"attester required / 需要认证者地址");
            // sanity al deploy: la fuente debe resolver a un attester real (caza EOAs/basura)
            require(
                IAttesterSource(attesterSource_).attester() != address(0),
                unicode"attester required / 需要认证者地址"
            );
        }
        // TYPE_TWITTER: usa el XGeneralVerifier de Flap (chain-based, via factory). La factory
        // (newVault) RECHAZA crear un vault twitter si el verifier aun no esta desplegado en la
        // chain (preaudit High #2) -- por el flujo canonico, xVerifier_ nunca deberia llegar en 0
        // para este tipo. Si igual se deploya este vault directo (fuera de la factory) con
        // xVerifier_ = 0, claimByProof revierte hasta que exista.
    }

    /// @notice El Guardian oficial de Flap puede prender/apagar el forward de receive() hacia una
    ///         address de rescate. Audit v3 (High, finding 4): este vault es inmutable y solo tenia
    ///         emergencyWithdrawNative (after-the-fact); durante un incidente, sin este switch, el
    ///         tax que sigue entrando no se puede redirigir en el momento de la recepcion.
    function setRescueForward(bool on, address to) external {
        require(msg.sender == _getGuardian(), unicode"only guardian / 仅限 Guardian");
        require(!on || to != address(0), unicode"zero rescue target / 救援地址为空");
        rescueForward = on;
        rescueTo = to;
        emit RescueForwardSet(on, to);
    }

    /// @notice Recibe el tax del TaxProcessor de Flap.
    /// @dev Nunca revierte por logica propia: no hay ningun require/revert en el body. Si
    ///      `rescueForward` esta prendido (Guardian, Audit v3 finding 4), reenvia el msg.value a
    ///      `rescueTo` best-effort — si el forward falla, el ETH se queda ACA (rescatable via
    ///      emergencyWithdrawNative) y la recepcion igual no revierte. Sin ese switch, acumula en
    ///      el balance del vault exactamente como antes.
    ///      CONDICION DE GAS: con el forward prendido, el SLOAD + el `.call` externo superan el
    ///      stipend de 2300 gas de `transfer`/`send` — un caller que solo entregue ese stipend
    ///      puede revertir por out-of-gas aca. Flap entrega el tax con `.call` bajo Rule 005 (<1M
    ///      gas, sin stipend de 2300) — ver test/Fork.t.sol — asi que en el flujo real no aplica.
    receive() external payable {
        if (rescueForward && rescueTo != address(0)) {
            (bool ok,) = rescueTo.call{value: msg.value}("");
            if (ok) emit Forwarded(rescueTo, msg.value);
        }
    }

    function pendingAmount() public view returns (uint256) {
        return address(this).balance;
    }

    /// @dev Bytecode: mismo require repetido 5 veces en payouts distintos (claimAndBind,
    ///      claimByProof, sweep, recoverUnclaimed, emergencyWithdrawNative) — compartir el
    ///      string y la logica de revert en una sola funcion evita 5 copias del literal
    ///      bilingue. Este contrato se embebe entero en el initcode de SocialFeeEscrowFactory.
    function _requirePayout(bool ok) private pure {
        require(ok, unicode"payout failed / 支付失败");
    }

    /// @notice El attester VIGENTE (leido en vivo de la factory; rotable). Mismo ABI de lectura
    ///         que el viejo immutable — dApp y attester server no cambian.
    function attester() public view returns (address) {
        return identityType == TYPE_GITHUB ? IAttesterSource(attesterSource).attester() : address(0);
    }

    /// @notice Digest EIP-712 que el attester debe firmar para autorizar el bind actual.
    /// @dev Usa el bindNonce VIGENTE: el attester lo lee de aca via eth_call y firma
    ///      exactamente este hash — cero re-implementacion del typed-data off-chain.
    function bindDigest(address payoutWallet, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(BIND_TYPEHASH, payoutWallet, bindNonce, deadline)));
    }

    /// @notice Ruta GITHUB: prueba la identidad (voucher del attester) y cobra todo el balance.
    ///         Re-llamable con voucher fresco para re-bind (rotar wallet de cobro).
    ///         Twitter usa claimByProof; wallet usa sweep.
    function claimAndBind(address payoutWallet, uint256 deadline, bytes calldata signature) external {
        require(identityType == TYPE_GITHUB, unicode"github identity only / 仅限 github 身份");
        require(payoutWallet != address(0), unicode"zero payout / 收款地址为空");
        require(block.timestamp <= deadline, unicode"voucher expired / 凭证已过期");
        address signer = ECDSA.recover(bindDigest(payoutWallet, deadline), signature);
        require(signer == attester(), unicode"bad attester signature / 认证签名无效");

        emit Bound(payoutWallet, bindNonce);
        boundWallet = payoutWallet;
        unchecked {
            bindNonce++;
        }

        uint256 amount = address(this).balance;
        if (amount > 0) {
            totalPaid += amount; // efectos antes de la interaccion (CEI)
            emit Swept(payoutWallet, amount);
            (bool ok,) = payoutWallet.call{value: amount}("");
            _requirePayout(ok);
        }
    }

    // ───────────────────────── Ruta TWITTER/X: XGeneralVerifier oficial de Flap ─────────────────────────

    /// @notice El handle de X que debe postear el tweet de claim (el fondeado). Lowercase.
    /// @dev Fijo por vault (no depende del beneficiary). Lo lee el dApp al conectar.
    function expectedHandle(address) external view returns (string memory) {
        return identityValue;
    }

    /// @notice El substring EXACTO que el tweet de claim debe contener, único por wallet + vault.
    /// @dev Patrón del Gift Vault de Flap: address del claimer + el vault (esta address) como tag
    ///      único. Addresses en hex lowercase (Strings.toHexString). Match case-sensitive.
    function expectedTweet(address beneficiary) public view returns (string memory) {
        return string.concat(
            Strings.toHexString(beneficiary),
            " is claiming the tokens locked in the vault of ",
            Strings.toHexString(address(this))
        );
    }

    /// @notice Ruta TWITTER: prueba firmada por el oráculo de Flap (XGeneralVerifier) y cobra.
    ///         El claimer (msg.sender) es la wallet que recibe. Re-llamable con un tweet nuevo
    ///         (tweetId mayor) para re-bind a otra wallet.
    function claimByProof(IXGeneralVerifier.XGeneralProof calldata proof, bytes calldata signature) external {
        require(identityType == TYPE_TWITTER, unicode"twitter identity only / 仅限 twitter 身份");
        require(xVerifier != address(0), unicode"x verifier not on this chain yet / 本链暂无 X 验证器");
        // (1) substring ata la prueba a ESTA wallet (msg.sender) y a ESTE vault.
        require(
            keccak256(bytes(proof.substring)) == keccak256(bytes(expectedTweet(msg.sender))),
            unicode"substring mismatch / substring 不匹配"
        );
        // (2) el tweet debe ser del handle FONDEADO (el verifier devuelve el handle real, lowercase).
        //     Sin este check, cualquier cuenta que postee el substring podría reclamar.
        require(
            keccak256(bytes(proof.xHandle)) == keccak256(bytes(identityValue)),
            unicode"wrong x handle / X 账号不符"
        );
        // (3) firma del oráculo de Flap.
        require(IXGeneralVerifier(xVerifier).verify(proof, signature), unicode"invalid proof / 证明无效");
        // (4) replay GLOBAL: los Snowflake IDs crecen; exigimos estrictamente mayor que el ULTIMO
        // claim exitoso de CUALQUIER candidato (Audit v3, Low, finding 6). Antes era por-claimer
        // (lastTweetId[msg.sender]): una wallet vieja nombrada en un tweet desactualizado pero aun
        // oracle-valido podia reclamar despues de que el handle ya hubiera probado una wallet mas
        // nueva, desviando el balance acumulado para esta ultima. Un tweet mas nuevo invalida a
        // TODOS los anteriores, igual que el bindNonce de github invalida vouchers viejos.
        require(proof.tweetId > lastTweetId, unicode"outdated proof / 证明已过期");
        lastTweetId = proof.tweetId;

        emit Bound(msg.sender, bindNonce);
        boundWallet = msg.sender;
        unchecked {
            bindNonce++;
        }
        uint256 amount = address(this).balance;
        if (amount > 0) {
            totalPaid += amount;
            emit Swept(msg.sender, amount);
            (bool ok,) = msg.sender.call{value: amount}("");
            _requirePayout(ok);
        }
    }

    /// @notice Ruta WALLET: la identidad original puede rotar su wallet de cobro.
    /// @dev Fix del preaudit de Flap (Critical): si identityWallet es un contrato que no puede
    ///      recibir ETH (multisig mal configurado), sweep() revertiria para siempre sin recurso.
    ///      Como la identidad ES esa wallet, dejarla redirigir el payout preserva el modelo de
    ///      confianza ("solo la identidad probada dirige los fondos") y la rescata sola.
    function rebindWallet(address newPayout) external {
        require(identityType == TYPE_WALLET, unicode"wallet identity only / 仅限 wallet 身份");
        require(msg.sender == identityWallet, unicode"only identity wallet / 仅限身份钱包");
        require(newPayout != address(0), unicode"zero payout / 收款地址为空");
        emit Bound(newPayout, bindNonce);
        boundWallet = newPayout;
        unchecked {
            bindNonce++;
        }
    }

    /// @notice Envia todo el balance a la wallet ya probada. Permissionless a proposito:
    ///         cualquiera puede pagar el gas para empujar los fees a su dueno.
    function sweep() external {
        require(boundWallet != address(0), unicode"not bound yet / 尚未绑定");
        uint256 amount = address(this).balance;
        require(amount > 0, unicode"nothing to sweep / 无可领取余额");
        totalPaid += amount;
        emit Swept(boundWallet, amount);
        (bool ok,) = boundWallet.call{value: amount}("");
        _requirePayout(ok);
    }

    /// @notice Si la persona nunca aparecio y el creator fijo un plazo al launch,
    ///         devuelve el balance a una wallet que el creator elige. Nunca despues de un bind.
    /// @dev Fix del preaudit de Flap (High): el push fijo a `creator` podia trabar los fondos si
    ///      esa address era un contrato incapaz de recibir ETH. Con destino elegible la funcion
    ///      deja de ser permissionless: solo el creator decide adonde va SU recovery.
    function recoverUnclaimed(address to) external {
        require(msg.sender == creator, unicode"only creator / 仅限创建者");
        require(to != address(0), unicode"zero recipient / 接收地址为空");
        require(recoveryAfter != 0, unicode"recovery disabled / 回收未启用");
        require(boundWallet == address(0), unicode"already bound / 已绑定");
        require(block.timestamp >= recoveryAfter, unicode"too early / 未到回收时间");
        uint256 amount = address(this).balance;
        require(amount > 0, unicode"nothing to recover / 无可回收余额");
        totalPaid += amount;
        emit Recovered(to, amount);
        (bool ok,) = to.call{value: amount}("");
        _requirePayout(ok);
    }

    /// @notice Escape hatch de ultima instancia, gated al Guardian OFICIAL de Flap (per-chain,
    ///         heredado de VaultBase — no es una key nuestra ni del creator).
    /// @dev Adoptado del preaudit de Flap (Option A, patron de flap-sh/FlapVaultExample, Rule 009):
    ///      cubre los escenarios donde todo lo demas fallo (wallet-identidad muerta que tampoco
    ///      puede llamar rebindWallet, attester perdido sin sucesor, etc.). Decision de producto
    ///      explicita: se cede el claim "cero funciones privilegiadas" a cambio de que ningun
    ///      fondo pueda quedar trabado para siempre. CEI; sin totalPaid (no es payout de identidad).
    function emergencyWithdrawNative(address to) external onlyGuardian {
        require(to != address(0), unicode"zero recipient / 接收地址为空");
        uint256 amount = address(this).balance;
        if (amount > 0) {
            emit EmergencyWithdrawNative(to, amount);
            (bool ok,) = to.call{value: amount}("");
            _requirePayout(ok);
        }
    }

    /// @dev Audit v3 (High, finding 2, SYS-REQ-MULTILANG): esta view es user-facing (status banner
    ///      de la UI) igual que los require/revert, asi que ahora es bilingue — sentencia en ingles
    ///      completa, separador " / ", y su espejo en chino completo (no fragmentos mezclados, para
    ///      que ambos idiomas queden gramaticalmente coherentes).
    function description() public view override returns (string memory) {
        string memory id = identityType == TYPE_WALLET
            ? Strings.toHexString(boundWallet)
            : string.concat(identityType == TYPE_GITHUB ? "github:" : "x:", identityValue);
        string memory stateEn;
        string memory stateZh;
        if (boundWallet != address(0)) {
            stateEn = string.concat("bound to ", Strings.toHexString(boundWallet));
            stateZh = string.concat(unicode"已绑定至 ", Strings.toHexString(boundWallet));
        } else if (recoveryAfter != 0 && block.timestamp >= recoveryAfter) {
            stateEn = "unclaimed (recoverable by creator)";
            stateZh = unicode"未领取（创建者可回收）";
        } else {
            stateEn = "waiting for its person";
            stateZh = unicode"等待其主人认领";
        }
        string memory pendingEth = _fmtEth(address(this).balance);
        string memory paidEth = _fmtEth(totalPaid);
        string memory descEn = string.concat(
            "FLEDGE fee escrow for ",
            id,
            ": ",
            pendingEth,
            " ETH pending, ",
            paidEth,
            " ETH paid out. Status: ",
            stateEn,
            "."
        );
        string memory descZh = string.concat(
            unicode"FLEDGE 手续费托管，对象：",
            id,
            unicode"：待领取 ",
            pendingEth,
            unicode" ETH，已支付 ",
            paidEth,
            unicode" ETH。状态：",
            stateZh,
            unicode"。"
        );
        return string.concat(descEn, " / ", descZh);
    }

    function _fmtEth(uint256 weiAmount) internal pure returns (string memory) {
        uint256 milli = weiAmount / 1e15; // resolucion 0.001 ETH
        string memory frac = Strings.toString(milli % 1000);
        if (milli % 1000 < 10) frac = string.concat("00", frac);
        else if (milli % 1000 < 100) frac = string.concat("0", frac);
        return string.concat(Strings.toString(milli / 1000), ".", frac);
    }

    /// @dev Helpers de bytecode para vaultUISchema(): construir cada FieldDescriptor/array/metodo
    ///      inline (una vez por cada uno de los 7 metodos) duplica el codigo de asignacion de
    ///      struct en cada call site bajo via_ir. Centralizarlo en funciones internas hace que el
    ///      compilador comparta UN cuerpo via JUMP en vez de inlinearlo 7 veces — este contrato se
    ///      embebe entero en el initcode de SocialFeeEscrowFactory (`new SocialFeeEscrow(...)` en
    ///      `newVault`), asi que cada byte cuenta doble. Ver AUDIT-NOTES.md.
    function _fd(string memory name_, string memory type_, string memory desc_, uint8 dec_)
        private
        pure
        returns (FieldDescriptor memory)
    {
        return FieldDescriptor(name_, type_, desc_, dec_);
    }

    function _arr1(FieldDescriptor memory a) private pure returns (FieldDescriptor[] memory out) {
        out = new FieldDescriptor[](1);
        out[0] = a;
    }

    function _method(
        string memory name_,
        string memory desc_,
        FieldDescriptor[] memory ins_,
        FieldDescriptor[] memory outs_,
        bool isWrite_
    ) private pure returns (VaultMethodSchema memory) {
        return VaultMethodSchema(name_, desc_, ins_, outs_, new ApproveAction[](0), false, false, isWrite_);
    }

    /// @dev Audit v3 (High, finding 2, SYS-REQ-MULTILANG): todo string user-facing de este schema
    ///      (description de cada metodo y de cada campo) ahora es bilingue "English / 中文".
    /// @dev Pre-audit propio (doc-vs-code): el schema ahora enumera las 7 funciones user-facing del
    ///      vault (antes omitia claimByProof y recoverUnclaimed, dejando los vaults twitter y la
    ///      recovery de creator sin ruta de claim documentada), cumpliendo el mandate de
    ///      VaultBaseV2 de describir cada metodo que la UI deba poder renderizar. `expectedTweet`
    ///      queda fuera del schema (no es una accion de claim en si) por presupuesto de bytecode:
    ///      este contrato se embebe entero en el initcode de SocialFeeEscrowFactory via
    ///      `new SocialFeeEscrow(...)`, que ya viene justo bajo EIP-170 — ver AUDIT-NOTES.md.
    ///      Traducciones deliberadamente concisas (mismo motivo).
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        FieldDescriptor[] memory noFields = new FieldDescriptor[](0);
        schema.vaultType = "SocialFeeEscrow";
        schema.description = unicode"Escrow for one identity (wallet, GitHub or X); claims pay the proven wallet, "
            unicode"unclaimed funds may go to creator after deadline, Guardian can emergency-withdraw or "
            unicode"rescue-forward. / 单一身份手续费托管（钱包/GitHub/X）：认领付给已证明钱包，截止后未认领可归创建者，"
            unicode"Guardian 可紧急提取或救援转发。";
        schema.methods = new VaultMethodSchema[](7);

        schema.methods[0] = _method(
            "claimAndBind",
            unicode"GitHub: attester voucher binds wallet, claims ETH. "
                unicode"/ GitHub：认证者凭证绑定钱包并领取 ETH。",
            _arr3(
                _fd("payoutWallet", "address", unicode"Payout wallet / 收款钱包", 0),
                _fd("deadline", "time", unicode"Voucher expiry / 到期时间", 0),
                _fd("signature", "bytes", unicode"Voucher signature / 凭证签名", 0)
            ),
            noFields,
            true
        );

        schema.methods[1] = _method(
            "claimByProof",
            unicode"X: XGeneralVerifier proof binds msg.sender, claims ETH. "
                unicode"/ X：XGeneralVerifier 证明绑定 msg.sender 并领取 ETH。",
            noFields,
            noFields,
            true
        );

        schema.methods[2] = _method(
            "rebindWallet",
            unicode"Wallet: identity wallet rotates payout wallet. / 钱包：身份钱包可轮换收款钱包。",
            _arr1(_fd("newPayout", "address", unicode"New wallet / 新钱包", 0)),
            noFields,
            true
        );

        schema.methods[3] = _method(
            "sweep",
            unicode"Pushes pending ETH to bound wallet; anyone may pay gas. "
                unicode"/ 将待领 ETH 发送到绑定钱包，任何人可付 gas。",
            noFields,
            noFields,
            true
        );

        schema.methods[4] = _method(
            "recoverUnclaimed",
            unicode"Creator-only: after deadline, if unbound, sends balance to chosen address. "
                unicode"/ 仅创建者：截止后若未绑定，发送余额至指定地址。",
            noFields,
            noFields,
            true
        );

        schema.methods[5] = _method(
            "pendingAmount",
            unicode"Unpaid accumulated ETH. / 未支付的累积 ETH。",
            noFields,
            _arr1(_fd("pending", "uint256", unicode"Claimable ETH / 可领取 ETH", 18)),
            false
        );

        schema.methods[6] = _method(
            "boundWallet",
            unicode"Wallet that proved identity. / 已证明身份的钱包。",
            noFields,
            _arr1(_fd("wallet", "address", unicode"Zero until proven / 未证明前为零", 0)),
            false
        );
    }

    function _arr3(FieldDescriptor memory a, FieldDescriptor memory b, FieldDescriptor memory c)
        private
        pure
        returns (FieldDescriptor[] memory out)
    {
        out = new FieldDescriptor[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }
}
