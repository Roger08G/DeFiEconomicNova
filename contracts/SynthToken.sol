// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SynthToken
 * @notice ERC20 governance token with per-block balance snapshots.
 * @dev    Implements a minimal ERC-20 surface with an append-only snapshot
 *         array per account. Each transfer records the post-transfer balance
 *         at the current block, enabling historical voting-power lookups
 *         without relying on external checkpoint libraries.
 *
 *         Snapshot array entries are deduplicated within the same block:
 *         multiple transfers in one block update the last entry in-place
 *         rather than appending, keeping storage growth proportional to
 *         the number of distinct blocks with activity.
 *
 * @custom:security-contact security@novasynth.fi
 */
contract SynthToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;

    // ─── Snapshot system for governance ───
    struct Snapshot {
        uint256 blockNumber;
        uint256 balance;
    }
    mapping(address => Snapshot[]) private _snapshots;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "SynthToken: not owner");
        _snapshot(to);
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == owner || msg.sender == from, "SynthToken: not authorized");
        require(balanceOf[from] >= amount, "SynthToken: insufficient");
        _snapshot(from);
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "SynthToken: insufficient");
        _snapshot(msg.sender);
        _snapshot(to);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "SynthToken: insufficient");
        require(allowance[from][msg.sender] >= amount, "SynthToken: allowance");
        _snapshot(from);
        _snapshot(to);
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════
    // SNAPSHOT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Returns the token balance of `account` at the end of `blockNumber`.
     * @dev    Uses binary search over the per-account snapshot array.
     *         Returns 0 if `blockNumber` precedes the first recorded snapshot.
     *         Used by SynthGovernor to determine voting power at proposal creation.
     * @param  account     The address whose historical balance is queried.
     * @param  blockNumber The block at which to read the balance.
     * @return             Balance of `account` at `blockNumber`.
     */
    function balanceOfAt(address account, uint256 blockNumber) external view returns (uint256) {
        Snapshot[] storage snaps = _snapshots[account];

        if (snaps.length == 0) return 0;

        // Binary search for the snapshot at or before blockNumber
        if (blockNumber >= snaps[snaps.length - 1].blockNumber) {
            return snaps[snaps.length - 1].balance;
        }
        if (blockNumber < snaps[0].blockNumber) {
            return 0;
        }

        uint256 low = 0;
        uint256 high = snaps.length - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (snaps[mid].blockNumber <= blockNumber) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return snaps[low].balance;
    }

    function _snapshot(address account) internal {
        Snapshot[] storage snaps = _snapshots[account];
        if (snaps.length > 0 && snaps[snaps.length - 1].blockNumber == block.number) {
            // Already snapshotted this block — update in place
            snaps[snaps.length - 1].balance = balanceOf[account];
        } else {
            snaps.push(Snapshot({blockNumber: block.number, balance: balanceOf[account]}));
        }
    }
}
