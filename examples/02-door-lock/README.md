# Door Lock

## State Machine

```mermaid
stateDiagram
    Locked --> Open   : correct code
    Open   --> Locked : timeout
    Locked --> Locked : wrong code (attempts + 1)
```

