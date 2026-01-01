Gravity chain is a EVM L1 blockchain that uses the same Aptos consensus engine.
We are building a set of core contracts of Gravity chain in solidity.
Because the consensus engine includes everything Aptos has, we need to build a set of core contracts that are compatible with the Aptos consensus engine. We keep all the features of Aptos consensus engine, except for delegation. We simplify the reward distribution mechanism. Gravity's reward distribution mechanism is exactly the same as Ethereum's, EIP-1559. And we left the delegation part to each validator to implement their own delegation mechanism.
In our design, we prefer KISS (Keep It Simple Stupid) principle. We want to keep the code simple and easy to understand. 
